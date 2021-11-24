// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Runner V8 script for testing dart2wasm, takes ".wasm" file as argument.
// Run as follows:
//
// $> d8 --experimental-wasm-gc --wasm-gc-js-interop run_wasm.js -- <file_name>.wasm

function stringFromDartString(string) {
    return String.fromCharCode(...Array.from(string.$field2));
}

// Imports for printing and event loop
var dart2wasm = {
    printToConsole: function(string) {
        console.log(stringFromDartString(string))
    },
    scheduleCallback: function(milliseconds, closure) {
        setTimeout(function() {
            inst.exports.$call0(closure);
        }, milliseconds);
    }
};

// Create a Wasm module from the binary wasm file.
var bytes = readbuffer(arguments[0]);
var module = new WebAssembly.Module(bytes);

// Instantiate the Wasm module, importing from the global scope.
var importObject = (typeof window !== 'undefined')
    ? window
    : Realm.global(Realm.current());
var inst = new WebAssembly.Instance(module, importObject);

var result = inst.exports.main();
if (result) console.log(result);
