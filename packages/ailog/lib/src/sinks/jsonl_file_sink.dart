/// Platform-selecting entry point for the JSONL file sink.
///
/// On the VM and on mobile/desktop Flutter this resolves to the real
/// implementation; on the web it resolves to a stub that throws on
/// construction with an explanation.
library;

export 'jsonl_file_sink_io.dart'
    if (dart.library.js_interop) 'jsonl_file_sink_stub.dart';
