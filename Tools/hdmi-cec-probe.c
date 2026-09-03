#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const char *kCECFrameworkPath =
    "/System/Library/PrivateFrameworks/IOCEC.framework/IOCEC";

typedef struct {
    uint8_t bytes[16];
    uint8_t length_minus_one;
} IOCECFrame;

typedef void *(*IOCECInterfaceCreateWithServiceFn)(
    CFAllocatorRef allocator, io_service_t service);
typedef kern_return_t (*IOCECInterfaceSendFrameFn)(
    void *interface, const IOCECFrame *frame, uint32_t retry_count);
typedef kern_return_t (*IOCECInterfaceOpenReceiveQueueFn)(
    void *interface, bool snooping_enabled, uint32_t queue_depth);
typedef kern_return_t (*IOCECInterfaceSetLogicalAddressMaskFn)(
    void *interface, uint16_t address_mask);

static int send_volume_up_once(void) {
    void *handle = dlopen(kCECFrameworkPath, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "Cannot load Apple's CEC framework: %s\n", dlerror());
        return 1;
    }

    IOCECInterfaceCreateWithServiceFn interface_create =
        (IOCECInterfaceCreateWithServiceFn)dlsym(
            handle, "IOCECInterfaceCreateWithService");
    IOCECInterfaceSendFrameFn send_frame =
        (IOCECInterfaceSendFrameFn)dlsym(handle, "IOCECInterfaceSendFrame");
    IOCECInterfaceOpenReceiveQueueFn open_receive_queue =
        (IOCECInterfaceOpenReceiveQueueFn)dlsym(
            handle, "IOCECInterfaceOpenReceiveQueue");
    IOCECInterfaceSetLogicalAddressMaskFn set_address_mask =
        (IOCECInterfaceSetLogicalAddressMaskFn)dlsym(
            handle, "IOCECInterfaceSetLogicalAddressMask");
    if (interface_create == NULL || send_frame == NULL ||
        open_receive_queue == NULL ||
        set_address_mask == NULL) {
        fprintf(stderr, "The required private CEC functions are unavailable.\n");
        dlclose(handle);
        return 1;
    }

    void *interface = NULL;
    for (unsigned attempt = 0; attempt < 30000 && interface == NULL; attempt++) {
        io_service_t service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOAVCECService"));
        if (service != IO_OBJECT_NULL) {
            interface = interface_create(kCFAllocatorDefault, service);
            IOObjectRelease(service);
        }
        if (interface == NULL) {
            usleep(1000);
        }
    }

    if (interface == NULL) {
        fprintf(stderr,
                "No usable native CEC interface appeared within 30 seconds.\n"
                "No CEC frames were transmitted.\n");
        dlclose(handle);
        return 1;
    }

    kern_return_t open_result = open_receive_queue(interface, false, 100);
    if (open_result != KERN_SUCCESS) {
        fprintf(stderr,
                "Could not open the CEC interface (0x%x); no frame sent.\n",
                open_result);
        CFRelease(interface);
        dlclose(handle);
        return 1;
    }

    kern_return_t mask_result = set_address_mask(interface, (uint16_t)(1u << 4));
    if (mask_result != KERN_SUCCESS) {
        fprintf(stderr,
                "Could not claim CEC logical address 4 (0x%x); no frame sent.\n",
                mask_result);
        CFRelease(interface);
        dlclose(handle);
        return 1;
    }

    /* Playback Device 1 (4) -> Audio System (5): User Control Pressed,
       Volume Up. The release frame completes one key action. */
    const IOCECFrame press = {
        .bytes = {0x45, 0x44, 0x41},
        .length_minus_one = 2,
    };
    const IOCECFrame release = {
        .bytes = {0x45, 0x45},
        .length_minus_one = 1,
    };

    kern_return_t press_result = send_frame(interface, &press, 1);
    if (press_result != KERN_SUCCESS) {
        fprintf(stderr, "CEC Volume Up press failed (0x%x).\n", press_result);
        CFRelease(interface);
        dlclose(handle);
        return 1;
    }

    /* Queue the release immediately, before launchd's replacement corercd can
       reclaim the interface. Retry only transient queue/readiness failures. */
    kern_return_t release_result = KERN_FAILURE;
    for (unsigned attempt = 0; attempt < 20; attempt++) {
        release_result = send_frame(interface, &release, 1);
        if (release_result == KERN_SUCCESS) {
            break;
        }
        if (release_result != kIOReturnBusy &&
            release_result != kIOReturnTimeout &&
            release_result != kIOReturnNotReady &&
            release_result != kIOReturnNoSpace) {
            break;
        }
        usleep(1000);
    }
    if (release_result != KERN_SUCCESS) {
        fprintf(stderr,
                "CEC press was sent, but key release failed (0x%x).\n",
                release_result);
        CFRelease(interface);
        dlclose(handle);
        return 1;
    }

    printf("Sent one HDMI-CEC Volume Up action to logical address 5 "
           "(Audio System).\n");
    CFRelease(interface);
    dlclose(handle);
    return 0;
}

static void print_sysctl_string(const char *label, const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) {
        return;
    }

    char *value = calloc(1, size + 1);
    if (value == NULL) {
        return;
    }

    if (sysctlbyname(name, value, &size, NULL, 0) == 0) {
        printf("%-24s %s\n", label, value);
    }
    free(value);
}

static void print_cf_value(CFTypeRef value) {
    if (value == NULL) {
        printf("<missing>");
        return;
    }

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        char buffer[2048];
        if (CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer),
                               kCFStringEncodingUTF8)) {
            printf("%s", buffer);
        } else {
            printf("<non-UTF-8 string>");
        }
        return;
    }

    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        printf("%s", CFBooleanGetValue((CFBooleanRef)value) ? "yes" : "no");
        return;
    }

    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int64_t number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number)) {
            printf("%lld", (long long)number);
        } else {
            printf("<unprintable number>");
        }
        return;
    }

    CFStringRef description = CFCopyDescription(value);
    if (description == NULL) {
        printf("<unprintable>");
        return;
    }

    char buffer[2048];
    if (CFStringGetCString(description, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s", buffer);
    } else {
        printf("<non-UTF-8 value>");
    }
    CFRelease(description);
}

static void print_dictionary_value(CFDictionaryRef dictionary, CFStringRef key,
                                   const char *label) {
    if (dictionary == NULL) {
        return;
    }

    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (value == NULL) {
        return;
    }

    printf("      %-27s ", label);
    print_cf_value(value);
    printf("\n");
}

static void print_display_metadata(io_registry_entry_t entry) {
    CFTypeRef attributes_value = IORegistryEntryCreateCFProperty(
        entry, CFSTR("DisplayAttributes"), kCFAllocatorDefault, kNilOptions);
    if (attributes_value == NULL ||
        CFGetTypeID(attributes_value) != CFDictionaryGetTypeID()) {
        if (attributes_value != NULL) {
            CFRelease(attributes_value);
        }
        return;
    }

    CFDictionaryRef attributes = (CFDictionaryRef)attributes_value;
    CFTypeRef product_value =
        CFDictionaryGetValue(attributes, CFSTR("ProductAttributes"));
    if (product_value != NULL &&
        CFGetTypeID(product_value) == CFDictionaryGetTypeID()) {
        CFDictionaryRef product = (CFDictionaryRef)product_value;
        print_dictionary_value(product, CFSTR("ProductName"), "connected product");
        print_dictionary_value(product, CFSTR("ManufacturerID"), "manufacturer ID");
        print_dictionary_value(product, CFSTR("ProductID"), "product ID");
        print_dictionary_value(product, CFSTR("YearOfManufacture"),
                               "year manufactured");
    }

    CFRelease(attributes_value);
}

static void print_property(io_registry_entry_t entry, CFStringRef key,
                           const char *label) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        entry, key, kCFAllocatorDefault, kNilOptions);
    if (value == NULL) {
        return;
    }

    printf("      %-27s ", label);
    print_cf_value(value);
    printf("\n");
    CFRelease(value);
}

static void print_entry(io_registry_entry_t entry, unsigned depth) {
    io_name_t name = {0};
    io_name_t class_name = {0};
    io_string_t path = {0};
    uint64_t registry_id = 0;

    IORegistryEntryGetName(entry, name);
    IOObjectGetClass(entry, class_name);
    IORegistryEntryGetRegistryEntryID(entry, &registry_id);

    printf("  [%u] %s\n", depth, name[0] != '\0' ? name : "<unnamed>");
    printf("      %-27s %s\n", "class", class_name);
    printf("      %-27s 0x%llx\n", "registry ID",
           (unsigned long long)registry_id);

    if (IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS) {
        printf("      %-27s %s\n", "path", path);
    }

    print_property(entry, CFSTR("IOProviderClass"), "provider class");
    print_property(entry, CFSTR("IOUserClientClass"), "user-client class");
    print_property(entry, CFSTR("IOUserClientCreator"), "user-client owner");
    print_property(entry, CFSTR("IOCECInterfaceUserInterfaceSupported"),
                   "CEC user interface");
    print_property(entry, CFSTR("IOAVServiceUserInterfaceSupported"),
                   "AV user interface");
    print_property(entry, CFSTR("EPICName"), "EPIC endpoint");
    print_property(entry, CFSTR("interface-name"), "interface name");
    print_property(entry, CFSTR("Transport"), "display transport");
    print_property(entry, CFSTR("EDID UUID"), "EDID UUID");
    print_display_metadata(entry);
}

static unsigned print_matching_services(const char *class_name,
                                        const char *heading,
                                        bool include_parent_chain) {
    CFMutableDictionaryRef matching = IOServiceMatching(class_name);
    if (matching == NULL) {
        fprintf(stderr, "Could not create IOKit match for %s.\n", class_name);
        return 0;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, matching, &iterator);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "Could not enumerate %s (0x%x).\n", class_name, result);
        return 0;
    }

    printf("\n%s\n", heading);
    unsigned count = 0;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        count++;
        print_entry(service, 0);

        if (include_parent_chain) {
            io_registry_entry_t current = service;
            bool current_is_owned = false;
            for (unsigned depth = 1; depth <= 8; depth++) {
                io_registry_entry_t parent = IO_OBJECT_NULL;
                if (IORegistryEntryGetParentEntry(current, kIOServicePlane,
                                                  &parent) != KERN_SUCCESS) {
                    break;
                }
                if (current_is_owned) {
                    IOObjectRelease(current);
                }
                current = parent;
                current_is_owned = true;
                print_entry(current, depth);
            }
            if (current_is_owned) {
                IOObjectRelease(current);
            }
        }

        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (count == 0) {
        printf("  None found.\n");
    }
    return count;
}

static unsigned print_existing_cec_clients(void) {
    printf("\nExisting CEC user clients\n");

    CFMutableDictionaryRef matching = IOServiceMatching("IOAVCECService");
    if (matching == NULL) {
        printf("  None found.\n");
        return 0;
    }

    io_iterator_t services = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, matching, &services);
    if (result != KERN_SUCCESS) {
        printf("  Could not inspect CEC service children (0x%x).\n", result);
        return 0;
    }

    unsigned count = 0;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(services)) != IO_OBJECT_NULL) {
        io_iterator_t children = IO_OBJECT_NULL;
        if (IORegistryEntryGetChildIterator(service, kIOServicePlane,
                                            &children) == KERN_SUCCESS) {
            io_registry_entry_t child = IO_OBJECT_NULL;
            while ((child = IOIteratorNext(children)) != IO_OBJECT_NULL) {
                io_name_t class_name = {0};
                IOObjectGetClass(child, class_name);
                if (strcmp(class_name, "IOCECUserClient") == 0) {
                    print_entry(child, 0);
                    count++;
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(children);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(services);

    if (count == 0) {
        printf("  None found.\n");
    }
    return count;
}

static unsigned probe_private_framework(void) {
    static const char *symbols[] = {
        "IOCECInterfaceCreate",
        "IOCECInterfaceCreateWithService",
        "IOCECInterfaceCopyProperty",
        "IOCECInterfaceGetCECSnoopingEnabled",
        "IOCECInterfaceListenerCreate",
        "IOCECInterfaceListenerRegisterAddInterfaceCallback",
        "IOCECInterfaceListenerScheduleWithDispatchQueue",
        "IOCECInterfaceRegisterStatusCallback",
        "IOCECInterfaceRegisterTerminatedCallback",
        "IOCECInterfaceSendFrame",
        "IOCECInterfaceSetLogicalAddressMask",
    };

    printf("\nApple private CEC framework\n");
    void *handle = dlopen(kCECFrameworkPath, RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        printf("  Framework load:          unavailable (%s)\n", dlerror());
        return 0;
    }

    printf("  Framework load:          available\n");
    unsigned present = 0;
    const unsigned symbol_count =
        (unsigned)(sizeof(symbols) / sizeof(symbols[0]));
    for (unsigned i = 0; i < symbol_count; i++) {
        dlerror();
        void *symbol = dlsym(handle, symbols[i]);
        const char *error = dlerror();
        bool found = symbol != NULL && error == NULL;
        present += found ? 1u : 0u;
        printf("  %-45s %s\n", symbols[i], found ? "present" : "missing");
    }

    dlclose(handle);
    return present;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--volume-up") == 0) {
        return send_volume_up_once();
    }
    if (argc != 1) {
        fprintf(stderr, "Usage: %s [--volume-up]\n", argv[0]);
        return 2;
    }

    printf("VolumeKey native HDMI-CEC probe\n");
    printf("================================\n");
    printf("Mode: read-only capability inspection\n");
    printf("CEC frames transmitted: NO\n");
    printf("CEC receive queue opened: NO\n");
    printf("CEC logical address claimed: NO\n\n");

    print_sysctl_string("Mac model:", "hw.model");
    print_sysctl_string("macOS version:", "kern.osproductversion");
    print_sysctl_string("Kernel architecture:", "hw.machine");

    unsigned cec_services = print_matching_services(
        "IOAVCECService", "Native CEC services and provider chain", true);
    unsigned cec_clients = print_existing_cec_clients();
    unsigned hdmi_controllers = print_matching_services(
        "IODPHDMIPortController", "Native HDMI port controllers", false);
    unsigned display_links = print_matching_services(
        "IOMobileFramebufferShim", "Active display links", false);
    unsigned private_symbols = probe_private_framework();

    printf("\nVerdict\n");
    printf("  Native CEC service:      %s\n",
           cec_services > 0 ? "AVAILABLE" : "NOT DETECTED");
    printf("  Existing CEC client:     %s\n",
           cec_clients > 0 ? "ACTIVE" : "none observed");
    printf("  HDMI port controller:    %s\n",
           hdmi_controllers > 0 ? "AVAILABLE" : "NOT DETECTED");
    printf("  Active display link:     %s\n",
           display_links > 0 ? "AVAILABLE" : "NOT DETECTED");
    printf("  Private CEC API surface: %s (%u/11 symbols found)\n",
           private_symbols == 11 ? "COMPLETE" :
           (private_symbols > 0 ? "PARTIAL" : "NOT DETECTED"), private_symbols);
    printf("  Probe transmission:      NONE\n");

    if (cec_services == 0) {
        printf("\nNo live Apple CEC service was found. This can mean the Mac or "
               "display path lacks native CEC, or no compatible HDMI link is "
               "active.\n");
        return 1;
    }

    return 0;
}
