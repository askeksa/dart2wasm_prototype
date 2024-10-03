// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

import "unreachable_loading_unit_deferred.dart" deferred as lib;

unreachable() async {
  await lib.loadLibrary();
  lib.foo();
}
