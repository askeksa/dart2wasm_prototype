// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

import "package:expect/expect.dart";

class A {}

class B extends A {}

Iterable<B> f(Iterable<A> a) sync* {
  yield* a;
}

void main() {
  B b = new B();
  for (var x in f(<B>[b])) {} // No error
  var iterator = f(<A>[b]).iterator;
  Expect.throwsTypeError(() {
    iterator.moveNext();
  });
}
