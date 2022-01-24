// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "internal_patch.dart";

@pragma("wasm:entry-point")
class ClassID {
  @pragma("vm:external-name", "ClassID_getID")
  external static int getID(Object value);

  // TODO(askesc): Implement this as intrinsic when adding predefined cids.
  static final int numPredefinedCids = 1;
}
