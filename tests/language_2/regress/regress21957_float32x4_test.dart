// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

// Check slow path for PotentialUnboxedStore.
// VMOptions=--optimization_counter_threshold=-1

import "dart:typed_data";

main() {
  for (int i = 0; i < 1000000; i++) {
    new A();
  }
}

class A {
  var a = new Float32x4(1.0, 2.0, 3.0, 4.0);
}
