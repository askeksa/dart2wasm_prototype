library dart.wasm.js_util;

dynamic callMethod(Object o, String method, List<Object?> args) native;
dynamic newObject() native;
bool hasProperty(Object o, Object name) native;
dynamic getProperty(Object o, Object name) native;
dynamic setProperty(Object o, Object name, Object? value) native;
