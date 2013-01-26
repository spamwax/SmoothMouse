
#include "mouse.h"
#include "debug.h"

#include <sys/time.h>
#include <IOKit/hidsystem/event_status_driver.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include "WindowsFunction.hpp"

#define LEFT_BUTTON     4
#define RIGHT_BUTTON    1
#define MIDDLE_BUTTON   2
#define BUTTON4         8
#define BUTTON5         16
#define BUTTON6         32
#define NUM_BUTTONS     6

#define BUTTON_DOWN(curbuttons, button)                         (((button) & curbuttons) == (button))
#define BUTTON_UP(curbuttons, button)                           (((button) & curbuttons) == 0)
#define BUTTON_STATE_CHANGED(curbuttons, lastbuttons, button)   ((lastButtons & (button)) != (curbuttons & (button)))

WindowsFunction *win = NULL;

mach_port_t io_master_port = MACH_PORT_NULL;
io_connect_t gEventDriver = MACH_PORT_NULL;

extern BOOL is_debug;

extern double velocity_mouse;
extern double velocity_trackpad;
extern AccelerationCurve curve_mouse;
extern AccelerationCurve curve_trackpad;
extern Driver driver;

static CGEventSourceRef eventSource = NULL;
static CGPoint deltaPosInt;
static CGPoint deltaPosFloat;
static CGPoint currentPos;
static CGPoint lastPos;
static int lastButtons = 0;
static int nclicks = 0;
static CGPoint lastClickPos;
static double lastClickTime = 0;
static double clickTime;
static uint64_t lastSequenceNumber = 0;

static double timestamp()
{
	struct timeval t;
	gettimeofday(&t, NULL);
	return (double)t.tv_sec + 1.0e-6 * (double)t.tv_usec;
}

static double get_distance(CGPoint pos0, CGPoint pos1) {
    CGFloat deltaX = pos1.x - pos0.x;
    CGFloat deltaY = pos1.y - pos0.y;
    CGFloat distance = sqrt(deltaX * deltaX + deltaY * deltaY);
    return distance;
}

static const char *event_type_to_string(CGEventType type) {
    switch(type) {
        case kCGEventNull:              return "kCGEventNull";
        case kCGEventLeftMouseUp:       return "kCGEventLeftMouseUp";
        case kCGEventLeftMouseDown:     return "kCGEventLeftMouseDown";
        case kCGEventLeftMouseDragged:  return "kCGEventLeftMouseDragged";
        case kCGEventRightMouseUp:      return "kCGEventRightMouseUp";
        case kCGEventRightMouseDown:    return "kCGEventRightMouseDown";
        case kCGEventRightMouseDragged: return "kCGEventRightMouseDragged";
        case kCGEventOtherMouseUp:      return "kCGEventOtherMouseUp";
        case kCGEventOtherMouseDown:    return "kCGEventOtherMouseDown";
        case kCGEventOtherMouseDragged: return "kCGEventOtherMouseDragged";
        case kCGEventMouseMoved:        return "kCGEventMouseMoved";
        default:                        return "?";
    }
}

static CGPoint restrict_to_screen_boundaries(CGPoint lastPos, CGPoint newPos) {
    /*
	 The following code checks if cursor is in screen borders. It was ported
	 from Synergy.
	 */
    CGPoint pos = newPos;
    CGDisplayCount displayCount = 0;
	CGGetDisplaysWithPoint(newPos, 0, NULL, &displayCount);
	if (displayCount == 0) {
		displayCount = 0;
		CGDirectDisplayID displayID;
		CGGetDisplaysWithPoint(lastPos, 1,
							   &displayID, &displayCount);
		if (displayCount != 0) {
			CGRect displayRect = CGDisplayBounds(displayID);
			if (pos.x < displayRect.origin.x) {
				pos.x = displayRect.origin.x;
			}
			else if (pos.x > displayRect.origin.x +
					 displayRect.size.width - 1) {
				pos.x = displayRect.origin.x + displayRect.size.width - 1;
			}
			if (pos.y < displayRect.origin.y) {
				pos.y = displayRect.origin.y;
			}
			else if (pos.y > displayRect.origin.y +
					 displayRect.size.height - 1) {
				pos.y = displayRect.origin.y + displayRect.size.height - 1;
			}
		}
	}
    return pos;
}

static CGPoint get_current_mouse_pos() {
    CGEventRef event = CGEventCreate(NULL);
    CGPoint currentPos = CGEventGetLocation(event);
    CFRelease(event);
    return currentPos;
}

bool mouse_init() {

    NXEventHandle handle = NXOpenEventStatus();
	clickTime = NXClickTime(handle);
    NXCloseEventStatus(handle);

	deltaPosFloat = deltaPosInt = get_current_mouse_pos();

    switch (driver) {
        case DRIVER_QUARTZ_OLD:
            if (CGSetLocalEventsFilterDuringSuppressionState(kCGEventFilterMaskPermitAllEvents,
                                                             kCGEventSuppressionStateRemoteMouseDrag)) {
                NSLog(@"call to CGSetLocalEventsFilterDuringSuppressionState failed");
            }

            if (CGSetLocalEventsSuppressionInterval(0.0)) {
                NSLog(@"call to CGSetLocalEventsSuppressionInterval failed");
            }
            break;
        case DRIVER_QUARTZ:
            eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            if (eventSource == NULL) {
                NSLog(@"call to CGEventSourceSetKeyboardType failed");
            }
            break;
        case DRIVER_IOHID:
            // TODO: rewrite
            kern_return_t kr;
            mach_port_t ev;
            mach_port_t service;

            if (KERN_SUCCESS == (kr = IOMasterPort(MACH_PORT_NULL, &io_master_port)) && io_master_port != MACH_PORT_NULL) {
                if ((service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(kIOHIDSystemClass)))) {
                    kr = IOServiceOpen(service, mach_task_self(), kIOHIDParamConnectType, &ev);
                    IOObjectRelease(service);

                    if (KERN_SUCCESS == kr)
                        gEventDriver = ev;
                }
            }
            break;
    }

	return YES;
}

void mouse_cleanup() {
    if (win != NULL) {
        delete win;
        win = NULL;
    }

    switch (driver) {
        case DRIVER_QUARTZ_OLD:
            break;
        case DRIVER_QUARTZ:
            CFRelease(eventSource);
            break;
        case DRIVER_IOHID:
            kern_return_t   r = KERN_SUCCESS;
            if (gEventDriver != MACH_PORT_NULL)
                r = IOServiceClose(gEventDriver);
            gEventDriver = MACH_PORT_NULL;
            break;
    }
}

static void mouse_handle_move(int dx, int dy, double velocity, AccelerationCurve curve, int currentButtons) {
    CGPoint newPos;

    float calcdx;
    float calcdy;

    if (curve == ACCELERATION_CURVE_WINDOWS) {
        // map slider to [-5 <=> +5]
        int slider = (int)((velocity * 4) - 6);
        if (slider > 5) {
            slider = 5;
        }
        if (win == NULL) {
            win = new WindowsFunction(slider);
        }
        if (win->slider != slider) {
            delete win;
            win = new WindowsFunction(slider);
        }
        int newdx;
        int newdy;
        win->apply(dx, dy, &newdx, &newdy);
        calcdx = (float) newdx;
        calcdy = (float) newdy;
    } else {
        calcdx = (velocity * dx);
        calcdy = (velocity * dy);
    }

    newPos.x = currentPos.x + calcdx;
    newPos.y = currentPos.y + calcdy;

    newPos = restrict_to_screen_boundaries(currentPos, newPos);

    CGEventType eventType = kCGEventMouseMoved;
    CGMouseButton otherButton = 0;

    if (BUTTON_DOWN(currentButtons, LEFT_BUTTON)) {
        eventType = kCGEventLeftMouseDragged;
        otherButton = kCGMouseButtonLeft;
    } else if (BUTTON_DOWN(currentButtons, RIGHT_BUTTON)) {
        eventType = kCGEventRightMouseDragged;
        otherButton = kCGMouseButtonRight;
    } else if (BUTTON_DOWN(currentButtons, MIDDLE_BUTTON)) {
        eventType = kCGEventOtherMouseDragged;
        otherButton = kCGMouseButtonCenter;
    } else if (BUTTON_DOWN(currentButtons, BUTTON4)) {
        eventType = kCGEventOtherMouseDragged;
        otherButton = 3;
    } else if (BUTTON_DOWN(currentButtons, BUTTON5)) {
        eventType = kCGEventOtherMouseDragged;
        otherButton = 4;
    } else if (BUTTON_DOWN(currentButtons, BUTTON6)) {
        eventType = kCGEventOtherMouseDragged;
        otherButton = 5;
    }

    deltaPosFloat.x += calcdx;
    deltaPosFloat.y += calcdy;
    int deltaX = (int) (deltaPosFloat.x - deltaPosInt.x);
    int deltaY = (int) (deltaPosFloat.y - deltaPosInt.y);
    deltaPosInt.x += deltaX;
    deltaPosInt.y += deltaY;

    if (is_debug) {
        LOG(@"move dx: %d, dy: %d, cur: %.2fx%.2f, delta: %.2fx%.2f, buttons(LMR456): %d%d%d%d%d%d, eventType: %s(%d), otherButton: %d",
            dx,
            dy,
            currentPos.x,
            currentPos.y,
            deltaPosInt.x,
            deltaPosInt.y,
            BUTTON_DOWN(currentButtons, LEFT_BUTTON),
            BUTTON_DOWN(currentButtons, MIDDLE_BUTTON),
            BUTTON_DOWN(currentButtons, RIGHT_BUTTON),
            BUTTON_DOWN(currentButtons, BUTTON4),
            BUTTON_DOWN(currentButtons, BUTTON5),
            BUTTON_DOWN(currentButtons, BUTTON6),
            event_type_to_string(eventType),
            eventType,
            otherButton);
    }

    switch (driver) {
        case DRIVER_QUARTZ_OLD:
        {
            t1 = t3 = GET_TIME();
            if (kCGErrorSuccess != CGPostMouseEvent(newPos, true, 1, BUTTON_DOWN(currentButtons, LEFT_BUTTON))) {
                NSLog(@"Failed to post mouse event");
                exit(0);
            }
            t2 = t4 = GET_TIME();
            break;
        }
        case DRIVER_QUARTZ:
        {
            t1 = GET_TIME();
            CGEventRef evt = CGEventCreateMouseEvent(eventSource, eventType, newPos, otherButton);
            CGEventSetIntegerValueField(evt, kCGMouseEventDeltaX, deltaX);
            CGEventSetIntegerValueField(evt, kCGMouseEventDeltaY, deltaY);
            t3 = GET_TIME();
            CGEventPost(kCGSessionEventTap, evt);
            t4 = GET_TIME();
            CFRelease(evt);
            t2 = GET_TIME();
            break;
        }
        case DRIVER_IOHID:
        {
            int iohidEventType;

            t1 = GET_TIME();

            switch (eventType) {
                case kCGEventMouseMoved:
                    iohidEventType = NX_MOUSEMOVED;
                    break;
                case kCGEventLeftMouseDragged:
                    iohidEventType = NX_LMOUSEDRAGGED;
                    break;
                case kCGEventRightMouseDragged:
                    iohidEventType = NX_RMOUSEDRAGGED;
                    break;
                case kCGEventOtherMouseDragged:
                    iohidEventType = NX_OMOUSEDRAGGED;
                    break;
                default:
                    NSLog(@"INTERNAL ERROR: unknown eventType: %d", eventType);
                    exit(0);
            }

            static NXEventData eventData;
            memset(&eventData, 0, sizeof(NXEventData));

            IOGPoint newPoint = { (SInt16) newPos.x, (SInt16) newPos.y };

            eventData.mouseMove.dx = (SInt32)(deltaX);
            eventData.mouseMove.dy = (SInt32)(deltaY);

            t3 = GET_TIME();
            (void)IOHIDPostEvent(gEventDriver,
                                 iohidEventType,
                                 newPoint,
                                 &eventData,
                                 kNXEventDataVersion,
                                 0,
                                 kIOHIDSetCursorPosition);
            t2 = t4 = GET_TIME();
            break;
        }
        default:
        {
            NSLog(@"Driver %d not implemented: ", driver);
            exit(0);
        }
    }

    currentPos = newPos;
}

static void mouse_handle_buttons(int buttons) {

    CGEventType eventType = kCGEventNull;

    for(int i = 0; i < NUM_BUTTONS; i++) {
        int buttonIndex = (1 << i);
        if (BUTTON_STATE_CHANGED(buttons, lastButtons, buttonIndex)) {
            if (BUTTON_DOWN(buttons, buttonIndex)) {
                switch(buttonIndex) {
                    case LEFT_BUTTON:   eventType = kCGEventLeftMouseDown; break;
                    case RIGHT_BUTTON:  eventType = kCGEventRightMouseDown; break;
                    default:            eventType = kCGEventOtherMouseDown; break;
                }
            } else {
                switch(buttonIndex) {
                    case LEFT_BUTTON:   eventType = kCGEventLeftMouseUp; break;
                    case RIGHT_BUTTON:  eventType = kCGEventRightMouseUp; break;
                    default:            eventType = kCGEventOtherMouseUp; break;
                }
            }

            CGMouseButton otherButton = 0;
            switch(buttonIndex) {
                case LEFT_BUTTON: otherButton = kCGMouseButtonLeft; break;
                case RIGHT_BUTTON: otherButton = kCGMouseButtonRight; break;
                case MIDDLE_BUTTON: otherButton = kCGMouseButtonCenter; break;
                case BUTTON4: otherButton = 3; break;
                case BUTTON5: otherButton = 4; break;
                case BUTTON6: otherButton = 5; break;
            }

            if (eventType == kCGEventLeftMouseDown) {
                CGFloat maxDistanceAllowed = sqrt(2) + 0.0001;
                CGFloat distanceMovedSinceLastClick = get_distance(lastClickPos, currentPos);
                double now = timestamp();
                if (now - lastClickTime <= clickTime &&
                    distanceMovedSinceLastClick <= maxDistanceAllowed) {
                    lastClickTime = timestamp();
                    nclicks++;
                } else {
                    nclicks = 1;
                    lastClickTime = timestamp();
                    lastClickPos = currentPos;
                }
            }

            int clickStateValue;
            switch(eventType) {
                case kCGEventLeftMouseDown:
                case kCGEventLeftMouseUp:
                    clickStateValue = nclicks;
                    break;
                case kCGEventRightMouseDown:
                case kCGEventOtherMouseDown:
                case kCGEventRightMouseUp:
                case kCGEventOtherMouseUp:
                    clickStateValue = 1;
                    break;
                default:
                    clickStateValue = 0;
                    break;
            }

            if (is_debug) {
                LOG(@"buttons(LMR456): %d%d%d%d%d%d, eventType: %s(%d), otherButton: %d, buttonIndex(654LMR): %d, nclicks: %d, csv: %d",
                    BUTTON_DOWN(buttons, LEFT_BUTTON),
                    BUTTON_DOWN(buttons, MIDDLE_BUTTON),
                    BUTTON_DOWN(buttons, RIGHT_BUTTON),
                    BUTTON_DOWN(buttons, BUTTON4),
                    BUTTON_DOWN(buttons, BUTTON5),
                    BUTTON_DOWN(buttons, BUTTON6),
                    event_type_to_string(eventType),
                    eventType,
                    otherButton,
                    ((int)log2(buttonIndex)),
                    nclicks,
                    clickStateValue);
            }

            switch (driver) {
                case DRIVER_QUARTZ_OLD:
                {
                    t1 = t3 = GET_TIME();
                    if (kCGErrorSuccess != CGPostMouseEvent(currentPos, true, 1, BUTTON_DOWN(buttons, LEFT_BUTTON))) {
                        NSLog(@"Failed to post mouse event");
                        exit(0);
                    }
                    t2 = t4 = GET_TIME();
                    break;
                }
                case DRIVER_QUARTZ:
                {
                    t1 = GET_TIME();
                    CGEventRef evt = CGEventCreateMouseEvent(eventSource, eventType, currentPos, otherButton);
                    CGEventSetIntegerValueField(evt, kCGMouseEventClickState, clickStateValue);
                    t3 = GET_TIME();
                    CGEventPost(kCGSessionEventTap, evt);
                    t4 = GET_TIME();
                    CFRelease(evt);
                    t2 = GET_TIME();
                    break;
                }
                case DRIVER_IOHID:
                {
                    int iohidEventType;

                    t1 = GET_TIME();
                    switch(eventType) {
                        case kCGEventLeftMouseDown:
                            iohidEventType = NX_LMOUSEDOWN;
                            break;
                        case kCGEventLeftMouseUp:
                            iohidEventType = NX_LMOUSEUP;
                            break;
                        case kCGEventRightMouseDown:
                            iohidEventType = NX_RMOUSEDOWN;
                            break;
                        case kCGEventRightMouseUp:
                            iohidEventType = NX_RMOUSEUP;
                            break;
                        case kCGEventOtherMouseDown:
                            iohidEventType = NX_OMOUSEDOWN;
                            break;
                        case kCGEventOtherMouseUp:
                            iohidEventType = NX_OMOUSEUP;
                            break;
                        default:
                            NSLog(@"INTERNAL ERROR: unknown eventType: %d", eventType);
                            exit(0);
                    }

                    static NXEventData eventData;
                    memset(&eventData, 0, sizeof(NXEventData));

                    eventData.mouse.subType = NX_SUBTYPE_DEFAULT;
                    eventData.mouse.click = clickStateValue;
                    eventData.mouse.buttonNumber = otherButton;

                    if (is_debug) {
                        NSLog(@"eventType: %d, subt: %d, click: %d, buttonNumber: %d",
                              iohidEventType,
                              eventData.mouse.subType,
                              eventData.mouse.click,
                              eventData.mouse.buttonNumber);
                    }

                    IOGPoint newPoint = { (SInt16) currentPos.x, (SInt16) currentPos.y };

                    t3 = GET_TIME();
                    IOHIDPostEvent(gEventDriver,
                                   iohidEventType,
                                   newPoint,
                                   &eventData,
                                   kNXEventDataVersion,
                                   0,
                                   0);

                    t2 = t4 = GET_TIME();
                    break;
                }
                default:
                {
                    NSLog(@"Driver %d not implemented: ", driver);
                    exit(0);
                }
            }
        }
    }

    lastButtons = buttons;
}

void mouse_handle(mouse_event_t *event) {

    if (event->seqnum != (lastSequenceNumber + 1)) {
        if (is_debug) {
            LOG(@"Cursor position dirty, need to fetch fresh");
        }
        currentPos = get_current_mouse_pos();
    }

    if (event->dx != 0 || event->dy != 0) {
        double velocity;
        AccelerationCurve curve;
        switch (event->device_type) {
            case kDeviceTypeMouse:
                velocity = velocity_mouse;
                curve = curve_mouse;
                break;
            case kDeviceTypeTrackpad:
                velocity = velocity_trackpad;
                curve = curve_trackpad;
                break;
            default:
                velocity = 1;
                NSLog(@"INTERNAL ERROR: device type not mouse or trackpad");
                exit(0);
        }

        mouse_handle_move(event->dx, event->dy, velocity, curve, event->buttons);
    }

    if (event->buttons != lastButtons) {
        mouse_handle_buttons(event->buttons);
    }

    if (is_debug) {
        debug_register_event(event);
    }
    
    lastSequenceNumber = event->seqnum;
    lastButtons = event->buttons;
    lastPos = currentPos;
}
