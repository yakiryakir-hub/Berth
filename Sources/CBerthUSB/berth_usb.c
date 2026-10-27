#include "berth_usb.h"

#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

struct berth_usb {
    IOUSBInterfaceInterface942 **intf;
    IOUSBDeviceInterface942 **dev;
    int intfOpen;
    int devOpen;
    IOReturn devStatus;
    uint8_t pipeIn, pipeOut, pipeInt;       /* pipe refs (1-based) */
    uint8_t addrIn, addrOut, addrInt;       /* endpoint addresses */
    uint16_t maxPacketIn;
    uint8_t ifaceNum;
    uint8_t speed;
};

static IOReturn open_device(berth_usb *u, io_service_t ifaceSvc, int flags) {
    io_registry_entry_t parent = 0;
    IOReturn kr = IORegistryEntryGetParentEntry(ifaceSvc, kIOServicePlane, &parent);
    if (kr != kIOReturnSuccess) return kr;
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(parent, kIOUSBDeviceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(parent);
    if (kr != kIOReturnSuccess || !plug) return kr ? kr : kIOReturnError;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942),
                                         (LPVOID *)&u->dev);
    IODestroyPlugInInterface(plug);
    if (hr || !u->dev) return kIOReturnError;
    kr = (flags & BERTH_USB_SEIZE_DEVICE) ? (*u->dev)->USBDeviceOpenSeize(u->dev)
                                          : (*u->dev)->USBDeviceOpen(u->dev);
    if (kr == kIOReturnSuccess) u->devOpen = 1;
    UInt8 s = 0;
    if ((*u->dev)->GetDeviceSpeed(u->dev, &s) == kIOReturnSuccess) u->speed = s;
    return kr;
}

IOReturn berth_usb_open(io_service_t svc, int flags, berth_usb **out) {
    berth_usb *u = calloc(1, sizeof *u);
    if (!u) return kIOReturnNoMemory;

    if (flags & BERTH_USB_OPEN_DEVICE) {
        u->devStatus = open_device(u, svc, flags);
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(svc, kIOUSBInterfaceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != kIOReturnSuccess || !plug) { berth_usb_close(u); return kr ? kr : kIOReturnError; }
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942),
                                         (LPVOID *)&u->intf);
    IODestroyPlugInInterface(plug);
    if (hr || !u->intf) { berth_usb_close(u); return kIOReturnError; }

    kr = (*u->intf)->USBInterfaceOpen(u->intf);
    if (kr != kIOReturnSuccess) { berth_usb_close(u); return kr; }
    u->intfOpen = 1;

    (*u->intf)->GetInterfaceNumber(u->intf, &u->ifaceNum);
    UInt8 n = 0;
    (*u->intf)->GetNumEndpoints(u->intf, &n);
    for (UInt8 i = 1; i <= n; i++) {
        UInt8 dir = 0, num = 0, type = 0, interval = 0;
        UInt16 mps = 0;
        if ((*u->intf)->GetPipeProperties(u->intf, i, &dir, &num, &type, &mps, &interval) != kIOReturnSuccess)
            continue;
        uint8_t addr = (uint8_t)(num | (dir == kUSBIn ? 0x80 : 0x00));
        if (type == kUSBBulk) {
            if (dir == kUSBIn)  { u->pipeIn = i;  u->addrIn = addr;  u->maxPacketIn = mps; }
            else                { u->pipeOut = i; u->addrOut = addr; }
        } else if (type == kUSBInterrupt && dir == kUSBIn) {
            u->pipeInt = i; u->addrInt = addr;
        }
    }
    *out = u;
    return kIOReturnSuccess;
}

void berth_usb_close(berth_usb *u) {
    if (!u) return;
    if (u->intf) {
        if (u->intfOpen) (*u->intf)->USBInterfaceClose(u->intf);
        (*u->intf)->Release(u->intf);
    }
    if (u->dev) {
        if (u->devOpen) (*u->dev)->USBDeviceClose(u->dev);
        (*u->dev)->Release(u->dev);
    }
    free(u);
}

IOReturn berth_usb_device_status(const berth_usb *u) { return u->devStatus; }
uint8_t  berth_usb_bulk_in_address(const berth_usb *u) { return u->addrIn; }
uint8_t  berth_usb_bulk_out_address(const berth_usb *u) { return u->addrOut; }
uint8_t  berth_usb_interrupt_in_address(const berth_usb *u) { return u->addrInt; }
uint16_t berth_usb_max_packet_in(const berth_usb *u) { return u->maxPacketIn; }
uint8_t  berth_usb_interface_number(const berth_usb *u) { return u->ifaceNum; }
uint8_t  berth_usb_device_speed(const berth_usb *u) { return u->speed; }

IOReturn berth_usb_write(berth_usb *u, const void *buf, uint32_t len, uint32_t timeoutMs, uint32_t *done) {
    if (done) *done = 0;
    if (!u->pipeOut) return kIOReturnNotFound;
    IOReturn kr = (*u->intf)->WritePipeTO(u->intf, u->pipeOut, (void *)buf, len, timeoutMs, timeoutMs);
    if (kr == kIOReturnSuccess && done) *done = len;
    return kr;
}

IOReturn berth_usb_read_bulk(berth_usb *u, void *buf, uint32_t len, uint32_t timeoutMs, uint32_t *done) {
    if (done) *done = 0;
    if (!u->pipeIn) return kIOReturnNotFound;
    UInt32 size = len;
    IOReturn kr = (*u->intf)->ReadPipeTO(u->intf, u->pipeIn, buf, &size, timeoutMs, timeoutMs);
    if (done) *done = size;
    return kr;
}

IOReturn berth_usb_read_interrupt(berth_usb *u, void *buf, uint32_t len, uint32_t *done) {
    if (done) *done = 0;
    if (!u->pipeInt) return kIOReturnNotFound;
    UInt32 size = len;
    IOReturn kr = (*u->intf)->ReadPipe(u->intf, u->pipeInt, buf, &size);
    if (done) *done = size;
    return kr;
}

IOReturn berth_usb_abort_bulk(berth_usb *u) {
    IOReturn a = u->pipeIn  ? (*u->intf)->AbortPipe(u->intf, u->pipeIn)  : kIOReturnSuccess;
    IOReturn b = u->pipeOut ? (*u->intf)->AbortPipe(u->intf, u->pipeOut) : kIOReturnSuccess;
    return a != kIOReturnSuccess ? a : b;
}

IOReturn berth_usb_abort_interrupt(berth_usb *u) {
    return u->pipeInt ? (*u->intf)->AbortPipe(u->intf, u->pipeInt) : kIOReturnSuccess;
}

IOReturn berth_usb_clear_stalls(berth_usb *u) {
    IOReturn a = u->pipeIn  ? (*u->intf)->ClearPipeStallBothEnds(u->intf, u->pipeIn)  : kIOReturnSuccess;
    IOReturn b = u->pipeOut ? (*u->intf)->ClearPipeStallBothEnds(u->intf, u->pipeOut) : kIOReturnSuccess;
    return a != kIOReturnSuccess ? a : b;
}

IOReturn berth_usb_control(berth_usb *u, uint8_t bmRequestType, uint8_t bRequest,
                           uint16_t wValue, uint16_t wIndex, void *data, uint16_t len,
                           uint32_t timeoutMs, uint32_t *done) {
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof req);
    req.bmRequestType = bmRequestType;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.wLength = len;
    req.pData = data;
    req.noDataTimeout = timeoutMs;
    req.completionTimeout = timeoutMs;
    IOReturn kr = (*u->intf)->ControlRequestTO(u->intf, 0, &req);
    if (done) *done = req.wLenDone;
    return kr;
}
