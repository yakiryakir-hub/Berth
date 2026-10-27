#ifndef BERTH_USB_H
#define BERTH_USB_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

/// Thin blocking wrapper over Apple's IOUSBLib (IOUSBInterfaceInterface), the
/// same user-space USB API libusb uses on macOS. All calls block; the Swift
/// side runs them on dedicated queues.
typedef struct berth_usb berth_usb;

enum {
    BERTH_USB_OPEN_DEVICE = 1,   /* also open the parent device (like libusb) */
    BERTH_USB_SEIZE_DEVICE = 2,  /* seize it from other clients */
};

/// Opens the MTP interface behind an IOUSBHostInterface registry service.
/// Returns an IOReturn; on success *out holds the handle.
IOReturn berth_usb_open(io_service_t interfaceService, int flags, berth_usb **out);
void berth_usb_close(berth_usb *u);

/// Result of the optional device-level open (kIOReturnSuccess if not requested).
IOReturn berth_usb_device_status(const berth_usb *u);

/// Endpoint layout discovered at open. Addresses are 0 when absent.
uint8_t  berth_usb_bulk_in_address(const berth_usb *u);
uint8_t  berth_usb_bulk_out_address(const berth_usb *u);
uint8_t  berth_usb_interrupt_in_address(const berth_usb *u);
uint16_t berth_usb_max_packet_in(const berth_usb *u);
uint8_t  berth_usb_interface_number(const berth_usb *u);
uint8_t  berth_usb_device_speed(const berth_usb *u);

/// Bulk/interrupt transfers. `done` receives the byte count. Timeouts are
/// milliseconds; 0 means wait forever (reads) or use none.
IOReturn berth_usb_write(berth_usb *u, const void *buf, uint32_t len, uint32_t timeoutMs, uint32_t *done);
IOReturn berth_usb_read_bulk(berth_usb *u, void *buf, uint32_t len, uint32_t timeoutMs, uint32_t *done);
IOReturn berth_usb_read_interrupt(berth_usb *u, void *buf, uint32_t len, uint32_t *done);

IOReturn berth_usb_abort_bulk(berth_usb *u);
IOReturn berth_usb_abort_interrupt(berth_usb *u);
IOReturn berth_usb_clear_stalls(berth_usb *u);

/// Class/vendor control request on the default pipe.
IOReturn berth_usb_control(berth_usb *u, uint8_t bmRequestType, uint8_t bRequest,
                           uint16_t wValue, uint16_t wIndex, void *data, uint16_t len,
                           uint32_t timeoutMs, uint32_t *done);

#endif
