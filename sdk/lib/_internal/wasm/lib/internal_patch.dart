// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:typed_data" show Uint8List;

/// The returned string is a [_OneByteString] with uninitialized content.
String allocateOneByteString(int length) native;

/// The [string] must be a [_OneByteString]. The [index] must be valid.
void writeIntoOneByteString(String string, int index, int codePoint) native;

/// It is assumed that [from] is a native [Uint8List] class and [to] is a
/// [_OneByteString]. The [fromStart] and [toStart] indices together with the
/// [length] must specify ranges within the bounds of the list / string.
void copyRangeFromUint8ListToOneByteString(
    Uint8List from, String to, int fromStart, int toStart, int length) {
  for (int i = 0; i < length; i++) {
    writeIntoOneByteString(to, toStart + i, from[fromStart + i]);
  }
}

/// The returned string is a [_TwoByteString] with uninitialized content.
String allocateTwoByteString(int length) native;

/// The [string] must be a [_TwoByteString]. The [index] must be valid.
void writeIntoTwoByteString(String string, int index, int codePoint) native;

String ensureTwoByteString(String string) native;

const bool has63BitSmis = false;

// Utility class now only used by the VM.
class Lists {
  static void copy(List src, int srcStart, List dst, int dstStart, int count) {
    if (srcStart < dstStart) {
      for (int i = srcStart + count - 1, j = dstStart + count - 1;
          i >= srcStart;
          i--, j--) {
        dst[j] = src[i];
      }
    } else {
      for (int i = srcStart, j = dstStart; i < srcStart + count; i++, j++) {
        dst[j] = src[i];
      }
    }
  }
}

// This function can be used to skip implicit or explicit checked down casts in
// the parts of the core library implementation where we know by construction the
// type of a value.
//
// Important: this is unsafe and must be used with care.
T unsafeCast<T>(Object? v) native "Internal_unsafeCast";

// Thomas Wang 64-bit mix.
// https://gist.github.com/badboy/6267743
int mix64(int n) {
  n = (~n) + (n << 21); // n = (n << 21) - n - 1;
  n = n ^ (n >>> 24);
  n = n * 265; // n = (n + (n << 3)) + (n << 8);
  n = n ^ (n >>> 14);
  n = n * 21; // n = (n + (n << 2)) + (n << 4);
  n = n ^ (n >>> 28);
  n = n + (n << 31);
  return n;
}

int floatToIntBits(double value) native;
double intBitsToFloat(int value) native;
int doubleToIntBits(double value) native;
double intBitsToDouble(int value) native;

// Exported call stubs to enable JS to call Dart closures. Since all closure
// parameters and returns are boxed (their Wasm type is #Top) the Wasm type of
// the closure will be the same as with all parameters and returns as dynamic.
// Thus, the unsafeCast succeeds, and as long as the passed argumnets have the
// correct types, the argument casts inside the closure will also succeed.

@pragma("wasm:export", "\$call0")
dynamic _callClosure0(dynamic closure) {
  return unsafeCast<dynamic Function()>(closure)();
}

@pragma("wasm:export", "\$call1")
dynamic _callClosure1(dynamic closure, dynamic arg1) {
  return unsafeCast<dynamic Function(dynamic)>(closure)(arg1);
}

@pragma("wasm:export", "\$call2")
dynamic _callClosure2(dynamic closure, dynamic arg1, dynamic arg2) {
  return unsafeCast<dynamic Function(dynamic, dynamic)>(closure)(arg1, arg2);
}

// Schedule a callback from JS via setTimeout.
void scheduleCallback(double millis, dynamic Function() callback)
    native "dart2wasm.scheduleCallback";
