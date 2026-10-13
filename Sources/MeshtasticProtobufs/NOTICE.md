# Meshtastic protobuf bindings

Generated Swift code for the Meshtastic protocol, produced with `protoc` 36.2 and `protoc-gen-swift` 1.38.1 from
https://github.com/meshtastic/protobufs at commit `95c5f8c1c4223bb27faa81417b90560037f8ad31` (3 Oct 2026).

The `.proto` definitions are licensed GPL-3.0 (see `LICENSE-GPL-3.0`), and so is the generated code. This target is
kept separate from the rest of the project so that boundary is explicit.

Regenerate:

    protoc --proto_path=<protobufs> --swift_out=Sources/MeshtasticProtobufs --swift_opt=Visibility=Public \
        meshtastic/{admin,atak,channel,config,connection_status,device_ui,deviceonly,field_metadata,localonly,mesh,module_config,portnums,telemetry,xmodem}.proto

then move the files out of the `meshtastic/` subdirectory.
