// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.


import 'package:expect/expect.dart';

class C<X> {
  factory C(X x, Type t) = D<X>;
}

class D<X> implements C<X> {
  D(X x, Type t) {
    Expect.equals(t, X);
  }
}

typedef T<X> = C<X>;

void main() {
  T(1, int);
}
