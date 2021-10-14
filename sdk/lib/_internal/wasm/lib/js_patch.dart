import "dart:_internal" show patch;

import 'dart:collection' show HashMap, ListMixin;

@patch
class JsObject {
  // The wrapped JS object.
  final Object _jsObject;

  // This should only be called from _wrapToDart
  JsObject._fromJs(this._jsObject) {
    assert(_jsObject != null);
  }
}

@patch
class JsArray<E> extends JsObject with ListMixin<E> {
  JsArray._fromJs(Object jsObject) : super._fromJs(jsObject);
}
