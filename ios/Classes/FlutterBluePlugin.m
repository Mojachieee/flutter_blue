#import "FlutterBluePlugin.h"
#import "Flutterblue.pbobjc.h"

@interface FlutterBluePlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *channel;
@property(nonatomic, retain) FlutterBlueStreamHandler *stateStreamHandler;
@property(nonatomic, retain) FlutterBlueStreamHandler *scanResultStreamHandler;
@property(nonatomic, retain) FlutterBlueStreamHandler *servicesDiscoveredStreamHandler;
@property(nonatomic, retain) CBCentralManager *centralManager;
@property(nonatomic) NSMutableDictionary *scannedPeripherals;
@end

@implementation FlutterBluePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:NAMESPACE @"/methods"
                                     binaryMessenger:[registrar messenger]];
    FlutterEventChannel* stateChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/state" binaryMessenger:[registrar messenger]];
    FlutterEventChannel* scanResultChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/scanResult" binaryMessenger:[registrar messenger]];
    FlutterEventChannel* servicesDiscoveredChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/servicesDiscovered" binaryMessenger:[registrar messenger]];
    FlutterEventChannel* characteristicReadChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/characteristicRead" binaryMessenger:[registrar messenger]];
    FlutterEventChannel* descriptorReadChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/descriptorRead" binaryMessenger:[registrar messenger]];
    FlutterEventChannel* characteristicNotifiedChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/characteristicNotified" binaryMessenger:[registrar messenger]];
    FlutterBluePlugin* instance = [[FlutterBluePlugin alloc] init];
    instance.channel = channel;
    instance.centralManager = [[CBCentralManager alloc] initWithDelegate:instance queue:nil];
    instance.scannedPeripherals = [NSMutableDictionary new];
    
    // STATE
    FlutterBlueStreamHandler* stateStreamHandler = [[FlutterBlueStreamHandler alloc] init];
    [stateChannel setStreamHandler:stateStreamHandler];
    instance.stateStreamHandler = stateStreamHandler;
    
    // SCAN RESULTS
    FlutterBlueStreamHandler* scanResultStreamHandler = [[FlutterBlueStreamHandler alloc] init];
    [scanResultChannel setStreamHandler:scanResultStreamHandler];
    instance.scanResultStreamHandler = scanResultStreamHandler;
    
    // SERVICES DISCOVERED
    FlutterBlueStreamHandler* servicesDiscoveredStreamHandler = [[FlutterBlueStreamHandler alloc] init];
    [servicesDiscoveredChannel setStreamHandler:servicesDiscoveredStreamHandler];
    instance.servicesDiscoveredStreamHandler = servicesDiscoveredStreamHandler;
    
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"state" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [self toFlutterData:[self toBluetoothStateProto:self->_centralManager.state]];
        result(data);
    } else if([@"isAvailable" isEqualToString:call.method]) {
        if(self.centralManager.state != CBManagerStateUnsupported && self.centralManager.state != CBManagerStateUnknown) {
            result(@(YES));
        } else {
            result(@(NO));
        }
    } else if([@"isOn" isEqualToString:call.method]) {
        if(self.centralManager.state == CBManagerStatePoweredOn) {
            result(@(YES));
        } else {
            result(@(NO));
        }
    } else if([@"startScan" isEqualToString:call.method]) {
        // Clear any existing scan results
        [self.scannedPeripherals removeAllObjects];
        // TODO: Request Permission?
        FlutterStandardTypedData *data = [call arguments];
        ProtosScanSettings *request = [[ProtosScanSettings alloc] initWithData:[data data] error:nil];
        // TODO: Implement UUID Service filter and iOS Scan Options (#34 #35)
        [self->_centralManager scanForPeripheralsWithServices:nil options:nil];
        result(nil);
    } else if([@"stopScan" isEqualToString:call.method]) {
        [self->_centralManager stopScan];
        result(nil);
    } else if([@"connect" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [call arguments];
        ProtosConnectRequest *request = [[ProtosConnectRequest alloc] initWithData:[data data] error:nil];
        NSString *remoteId = [request remoteId];
        CBPeripheral *peripheral = [self.scannedPeripherals objectForKey:remoteId];
        if(peripheral == nil) {
            result([FlutterError errorWithCode:@"connect"
                                       message:@"Peripheral not found in scannedPeripherals"
                                       details:nil]);
            return;
        }
        // TODO: Implement Connect options (#36)
        [_centralManager connectPeripheral:peripheral options:nil];
        result(nil);
    } else if([@"disconnect" isEqualToString:call.method]) {
        NSString *remoteId = [call arguments];
        @try {
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            [_centralManager cancelPeripheralConnection:peripheral];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"deviceState" isEqualToString:call.method]) {
        NSString *remoteId = [call arguments];
        @try {
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            result([self toFlutterData:[self toDeviceStateProto:peripheral state:peripheral.state]]);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"discoverServices" isEqualToString:call.method]) {
        NSString *remoteId = [call arguments];
        @try {
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            [peripheral discoverServices:nil];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"services" isEqualToString:call.method]) {
        NSString *remoteId = [call arguments];
        @try {
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            result([self toFlutterData:[self toServicesResultProto:peripheral]]);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"readCharacteristic" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [call arguments];
        ProtosReadCharacteristicRequest *request = [[ProtosReadCharacteristicRequest alloc] initWithData:[data data] error:nil];
        NSString *remoteId = [request remoteId];
        @try {
            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            // Find characteristic
            CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
            // Trigger a read
            [peripheral readValueForCharacteristic:characteristic];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"readDescriptor" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [call arguments];
        ProtosReadDescriptorRequest *request = [[ProtosReadDescriptorRequest alloc] initWithData:[data data] error:nil];
        NSString *remoteId = [request remoteId];
        @try {
            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            // Find characteristic
            CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
            // Find descriptor
            CBDescriptor *descriptor = [self locateDescriptor:[request descriptorUuid] characteristic:characteristic];
            [peripheral readValueForDescriptor:descriptor];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"writeCharacteristic" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [call arguments];
        ProtosWriteCharacteristicRequest *request = [[ProtosWriteCharacteristicRequest alloc] initWithData:[data data] error:nil];
        NSString *remoteId = [request remoteId];
        @try {
            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            // Find characteristic
            CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
            // Get correct write type
            CBCharacteristicWriteType type = ([request writeType] == ProtosWriteCharacteristicRequest_WriteType_WithoutResponse) ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
            // Write to characteristic
            [peripheral writeValue:[request value] forCharacteristic:characteristic type:type];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"writeDescriptor" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [call arguments];
        ProtosWriteDescriptorRequest *request = [[ProtosWriteDescriptorRequest alloc] initWithData:[data data] error:nil];
        NSString *remoteId = [request remoteId];
        @try {
            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            // Find characteristic
            CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
            // Find descriptor
            CBDescriptor *descriptor = [self locateDescriptor:[request descriptorUuid] characteristic:characteristic];
            // Write descriptor
            [peripheral writeValue:[request value] forDescriptor:descriptor];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else if([@"setNotification" isEqualToString:call.method]) {
        FlutterStandardTypedData *data = [call arguments];
        ProtosSetNotificationRequest *request = [[ProtosSetNotificationRequest alloc] initWithData:[data data] error:nil];
        NSString *remoteId = [request remoteId];
        @try {
            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            // Find characteristic
            CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
            // Set notification value
            [peripheral setNotifyValue:[request enable] forCharacteristic:characteristic];
            result(nil);
        } @catch(FlutterError *e) {
            result(e);
        }
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (CBPeripheral*)findPeripheral:(NSString*)remoteId {
    NSArray<CBPeripheral*> *peripherals = [_centralManager retrievePeripheralsWithIdentifiers:@[[[NSUUID alloc] initWithUUIDString:remoteId]]];
    CBPeripheral *peripheral;
    for(CBPeripheral *p in peripherals) {
        if([[p.identifier UUIDString] isEqualToString:remoteId]) {
            peripheral = p;
            break;
        }
    }
    if(peripheral == nil) {
        @throw [FlutterError errorWithCode:@"findPeripheral"
                                   message:@"Peripheral not found"
                                   details:nil];
    }
    return peripheral;
}

- (CBCharacteristic*)locateCharacteristic:(NSString*)characteristicId peripheral:(CBPeripheral*)peripheral serviceId:(NSString*)serviceId secondaryServiceId:(NSString*)secondaryServiceId {
    CBService *primaryService = [self getAttributeFromArray:serviceId array:[peripheral services]];
    if(primaryService == nil || [primaryService isPrimary] == false) {
        @throw [FlutterError errorWithCode:@"locateCharacteristic"
                                   message:@"service could not be located on the device"
                                   details:nil];
    }
    CBService *secondaryService;
    if(secondaryServiceId != nil) {
        secondaryService = [self getAttributeFromArray:secondaryServiceId array:[primaryService includedServices]];
        @throw [FlutterError errorWithCode:@"locateCharacteristic"
                                   message:@"secondary service could not be located on the device"
                                   details:nil];
    }
    CBService *service = (secondaryService != nil) ? secondaryService : primaryService;
    CBCharacteristic *characteristic = [self getAttributeFromArray:characteristicId array:[service characteristics]];
    if(characteristic == nil) {
        @throw [FlutterError errorWithCode:@"locateCharacteristic"
                                   message:@"characteristic could not be located on the device"
                                   details:nil];
    }
    return characteristic;
}

- (CBDescriptor*)locateDescriptor:(NSString*)descriptorId characteristic:(CBCharacteristic*)characteristic {
    CBDescriptor *descriptor = [self getAttributeFromArray:descriptorId array:[characteristic descriptors]];
    if(descriptor == nil) {
        @throw [FlutterError errorWithCode:@"locateDescriptor"
                                   message:@"descriptor could not be located on the device"
                                   details:nil];
    }
    return descriptor;
}

- (CBAttribute*)getAttributeFromArray:(NSString*)uuidString array:(NSArray<CBAttribute*>*)array {
    for(CBAttribute *a in array) {
        if([[a.UUID UUIDString] isEqualToString:uuidString]) {
            return a;
        }
    }
    return nil;
}

//
// CBCentralManagerDelegate methods
//
- (void)centralManagerDidUpdateState:(nonnull CBCentralManager *)central {
    if(_stateStreamHandler.sink != nil) {
        FlutterStandardTypedData *data = [self toFlutterData:[self toBluetoothStateProto:self->_centralManager.state]];
        self.stateStreamHandler.sink(data);
    }
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    [self.scannedPeripherals setObject:peripheral
                              forKey:[[peripheral identifier] UUIDString]];
    if(_scanResultStreamHandler.sink != nil) {
        FlutterStandardTypedData *data = [self toFlutterData:[self toScanResultProto:peripheral advertisementData:advertisementData RSSI:RSSI]];
        _scanResultStreamHandler.sink(data);
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    // Register self as delegate for peripheral
    [peripheral setDelegate:self];
    
    // Send connection state
    [_channel invokeMethod:@"DeviceState" arguments:[self toFlutterData:[self toDeviceStateProto:peripheral state:peripheral.state]]];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    // Unregister self as delegate for peripheral
    [peripheral setDelegate:nil];
    
    // Send connection state
    [_channel invokeMethod:@"DeviceState" arguments:[self toFlutterData:[self toDeviceStateProto:peripheral state:peripheral.state]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    
}

//
// CBPeripheralDelegate methods
//
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if(error != nil) {
        // handle error
        NSLog(@"didDiscoverServices failed");
        return;
    }
    if(_servicesDiscoveredStreamHandler.sink != nil) {
        ProtosDiscoverServicesResult *result = [self toServicesResultProto:peripheral];
        _servicesDiscoveredStreamHandler.sink([self toFlutterData:result]);
    }
}

//
// Proto Helper methods
//
- (FlutterStandardTypedData*)toFlutterData:(GPBMessage*)proto {
    FlutterStandardTypedData *data = [FlutterStandardTypedData typedDataWithBytes:[[proto data] copy]];
    return data;
}

- (ProtosBluetoothState*)toBluetoothStateProto:(CBManagerState)state {
    ProtosBluetoothState *result = [[ProtosBluetoothState alloc] init];
    switch(state) {
        case CBManagerStateResetting:
            [result setState:ProtosBluetoothState_State_TurningOn];
            break;
        case CBManagerStateUnsupported:
            [result setState:ProtosBluetoothState_State_Unavailable];
            break;
        case CBManagerStateUnauthorized:
            [result setState:ProtosBluetoothState_State_Unauthorized];
            break;
        case CBManagerStatePoweredOff:
            [result setState:ProtosBluetoothState_State_Off];
            break;
        case CBManagerStatePoweredOn:
            [result setState:ProtosBluetoothState_State_On];
            break;
        default:
            [result setState:ProtosBluetoothState_State_Unknown];
            break;
    }
    return result;
}

- (ProtosScanResult*)toScanResultProto:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    ProtosScanResult *result = [[ProtosScanResult alloc] init];
    [result setDevice:[self toDeviceProto:peripheral]];
    [result setRssi:[RSSI intValue]];
    ProtosAdvertisementData *ads = [[ProtosAdvertisementData alloc] init];
    [ads setLocalName:advertisementData[CBAdvertisementDataLocalNameKey]];
    [ads setManufacturerData:advertisementData[CBAdvertisementDataManufacturerDataKey]];
    NSDictionary *serviceData = advertisementData[CBAdvertisementDataServiceDataKey];
    for (CBUUID *uuid in serviceData) {
        [[ads serviceData] setObject:serviceData[uuid] forKey:uuid.UUIDString];
    }
    [ads setTxPowerLevel:[advertisementData[CBAdvertisementDataTxPowerLevelKey] intValue]];
    [ads setConnectable:[advertisementData[CBAdvertisementDataIsConnectable] boolValue]];
    [result setAdvertisementData:ads];
    return result;
}

- (ProtosBluetoothDevice*)toDeviceProto:(CBPeripheral *)peripheral {
    ProtosBluetoothDevice *result = [[ProtosBluetoothDevice alloc] init];
    [result setName:[peripheral name]];
    [result setRemoteId:[[peripheral identifier] UUIDString]];
    [result setType:ProtosBluetoothDevice_Type_Le]; // TODO: Does iOS differentiate?
    return result;
}

- (ProtosDeviceStateResponse*)toDeviceStateProto:(CBPeripheral *)peripheral state:(CBPeripheralState)state {
    ProtosDeviceStateResponse *result = [[ProtosDeviceStateResponse alloc] init];
    switch(state) {
        case CBPeripheralStateDisconnected:
            [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Disconnected];
            break;
        case CBPeripheralStateConnecting:
            [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Connecting];
            break;
        case CBPeripheralStateConnected:
            [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Connected];
            break;
        case CBPeripheralStateDisconnecting:
            [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Disconnecting];
            break;
    }
    [result setRemoteId:[[peripheral identifier] UUIDString]];
    return result;
}

- (ProtosDiscoverServicesResult*)toServicesResultProto:(CBPeripheral *)peripheral {
    ProtosDiscoverServicesResult *result = [[ProtosDiscoverServicesResult alloc] init];
    [result setRemoteId:[peripheral.identifier UUIDString]];
    NSMutableArray *servicesProtos = [NSMutableArray new];
    for(CBService *s in [peripheral services]) {
        [servicesProtos addObject:[self toServiceProto:peripheral service:s]];
    }
    [result setServicesArray:servicesProtos];
    return result;
}

- (ProtosBluetoothService*)toServiceProto:(CBPeripheral *)peripheral service:(CBService *)service  {
    ProtosBluetoothService *result = [[ProtosBluetoothService alloc] init];
    NSLog(@"peripheral uuid:%@", [peripheral.identifier UUIDString]);
    NSLog(@"service uuid:%@", [service.UUID UUIDString]);
    [result setRemoteId:[peripheral.identifier UUIDString]];
    [result setUuid:[service.UUID UUIDString]];
    [result setIsPrimary:[service isPrimary]];
    
    // Characteristic Array
    NSMutableArray *characteristicProtos = [NSMutableArray new];
    for(CBCharacteristic *c in [service characteristics]) {
        [characteristicProtos addObject:[self toCharacteristicProto:c]];
    }
    [result setCharacteristicsArray:characteristicProtos];
    
    // Included Services Array
    NSMutableArray *includedServicesProtos = [NSMutableArray new];
    for(CBService *s in [service includedServices]) {
        [includedServicesProtos addObject:[self toServiceProto:peripheral service:s]];
    }
    [result setIncludedServicesArray:includedServicesProtos];
    
    return result;
}

- (ProtosBluetoothCharacteristic*)toCharacteristicProto:(CBCharacteristic *)characteristic {
    ProtosBluetoothCharacteristic *result = [[ProtosBluetoothCharacteristic alloc] init];
    [result setUuid:[characteristic.UUID UUIDString]];
    [result setProperties:[self toCharacteristicPropsProto:characteristic.properties]];
    [result setValue:[characteristic value]];
    NSMutableArray *descriptorProtos = [NSMutableArray new];
    for(CBDescriptor *d in [characteristic descriptors]) {
        [descriptorProtos addObject:[self toDescriptorProto:d]];
    }
    [result setDescriptorsArray:descriptorProtos];
    if([characteristic.service isPrimary]) {
        [result setServiceUuid:[characteristic.service.UUID UUIDString]];
    } else {
        // Reverse search to find service and secondary service UUID
        for(CBService *s in [characteristic.service.peripheral services]) {
            for(CBService *ss in [s includedServices]) {
                if([[ss.UUID UUIDString] isEqualToString:[characteristic.service.UUID UUIDString]]) {
                    [result setServiceUuid:[s.UUID UUIDString]];
                    [result setSecondaryServiceUuid:[ss.UUID UUIDString]];
                    break;
                }
            }
        }
    }
    return result;
}

- (ProtosBluetoothDescriptor*)toDescriptorProto:(CBDescriptor *)descriptor {
    ProtosBluetoothDescriptor *result = [[ProtosBluetoothDescriptor alloc] init];
    [result setUuid:[descriptor.UUID UUIDString]];
    [result setCharacteristicUuid:[descriptor.characteristic.UUID UUIDString]];
    [result setServiceUuid:[descriptor.characteristic.service.UUID UUIDString]];
    [result setValue:[descriptor value]];
    return result;
}

- (ProtosCharacteristicProperties*)toCharacteristicPropsProto:(CBCharacteristicProperties)props {
    ProtosCharacteristicProperties *result = [[ProtosCharacteristicProperties alloc] init];
    [result setBroadcast:(props & CBCharacteristicPropertyBroadcast) != 0];
    [result setRead:(props & CBCharacteristicPropertyRead) != 0];
    [result setWriteWithoutResponse:(props & CBCharacteristicPropertyWriteWithoutResponse) != 0];
    [result setWrite:(props & CBCharacteristicPropertyWrite) != 0];
    [result setNotify:(props & CBCharacteristicPropertyNotify) != 0];
    [result setIndicate:(props & CBCharacteristicPropertyIndicate) != 0];
    [result setAuthenticatedSignedWrites:(props & CBCharacteristicPropertyAuthenticatedSignedWrites) != 0];
    [result setExtendedProperties:(props & CBCharacteristicPropertyExtendedProperties) != 0];
    [result setNotifyEncryptionRequired:(props & CBCharacteristicPropertyNotifyEncryptionRequired) != 0];
    [result setIndicateEncryptionRequired:(props & CBCharacteristicPropertyIndicateEncryptionRequired) != 0];
    return result;
}

@end

@implementation FlutterBlueStreamHandler

- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
    self.sink = eventSink;
    return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
    self.sink = nil;
    return nil;
}

@end

