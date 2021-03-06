package kiss;

using Std;

import kiss.Operand;
import kiss.ReaderExp;
import haxe.ds.Either;
import haxe.Constraints;
#if (!macro && hxnodejs)
import js.node.ChildProcess;
import js.node.Buffer;
#elseif sys
import sys.io.Process;
#end
import uuid.Uuid;

using StringTools;
using uuid.Uuid;

/** What functions that process Lists should do when there are more elements than expected **/
enum ExtraElementHandling {
    Keep; // Keep the extra elements
    Drop; // Drop the extra elements
    Throw; // Throw an error
}

class Prelude {
    static function variadic(op:(Operand, Operand) -> Null<Operand>, comparison = false):(Array<Operand>) -> Dynamic {
        return (l:kiss.List<Operand>) -> switch (Lambda.fold(l.slice(1), op, l[0])) {
            case null:
                false;
            case somethingElse if (comparison):
                true;
            case somethingElse:
                Operand.toDynamic(somethingElse);
        };
    }

    // Kiss arithmetic will incur overhead because of these switch statements, but the results will not be platform-dependent
    static function _add(a:Operand, b:Operand):Operand {
        return switch ([a, b]) {
            case [Left(str), Left(str2)]:
                Left(str2 + str);
            case [Right(f), Right(f2)]:
                Right(f + f2);
            default:
                throw 'cannot add mismatched types ${Operand.toDynamic(a)} and ${Operand.toDynamic(b)}';
        };
    }

    public static var add = variadic(_add);

    static function _subtract(val:Operand, from:Operand):Operand {
        return switch ([from, val]) {
            case [Right(from), Right(val)]:
                Right(from - val);
            default:
                throw 'cannot subtract ${Operand.toDynamic(val)} from ${Operand.toDynamic(from)}';
        }
    }

    public static var subtract = variadic(_subtract);

    static function _multiply(a:Operand, b:Operand):Operand {
        return switch ([a, b]) {
            case [Right(f), Right(f2)]:
                Right(f * f2);
            case [Left(a), Left(b)]:
                throw 'cannot multiply strings "$a" and "$b"';
            case [Right(i), Left(s)] | [Left(s), Right(i)] if (i % 1 == 0):
                var result = "";
                for (_ in 0...Math.floor(i)) {
                    result += s;
                }
                Left(result);
            default:
                throw 'cannot multiply ${Operand.toDynamic(a)} and ${Operand.toDynamic(b)}';
        };
    }

    public static var multiply = variadic(_multiply);

    static function _divide(bottom:Operand, top:Operand):Operand {
        return switch ([top, bottom]) {
            case [Right(f), Right(f2)]:
                Right(f / f2);
            default:
                throw 'cannot divide $top by $bottom';
        };
    }

    public static var divide = variadic(_divide);

    public static function mod(bottom:Operand, top:Operand):Operand {
        return Right(top.toFloat() % bottom.toFloat());
    }

    public static function pow(exponent:Operand, base:Operand):Operand {
        return Right(Math.pow(base.toFloat(), exponent.toFloat()));
    }

    static function _min(a:Operand, b:Operand):Operand {
        return Right(Math.min(a.toFloat(), b.toFloat()));
    }

    public static var min = variadic(_min);

    static function _max(a:Operand, b:Operand):Operand {
        return Right(Math.max(a.toFloat(), b.toFloat()));
    }

    public static var max = variadic(_max);

    static function _greaterThan(b:Operand, a:Operand):Null<Operand> {
        return if (a == null || b == null) null else if (a.toFloat() > b.toFloat()) b else null;
    }

    public static var greaterThan = variadic(_greaterThan, true);

    static function _greaterEqual(b:Operand, a:Operand):Null<Operand> {
        return if (a == null || b == null) null else if (a.toFloat() >= b.toFloat()) b else null;
    }

    public static var greaterEqual = variadic(_greaterEqual, true);

    static function _lessThan(b:Operand, a:Operand):Null<Operand> {
        return if (a == null || b == null) null else if (a.toFloat() < b.toFloat()) b else null;
    }

    public static var lessThan = variadic(_lessThan, true);

    static function _lesserEqual(b:Operand, a:Operand):Null<Operand> {
        return if (a == null || b == null) null else if (a.toFloat() <= b.toFloat()) b else null;
    }

    public static var lesserEqual = variadic(_lesserEqual, true);

    static function _areEqual(a:Operand, b:Operand):Null<Operand> {
        return if (a == null || b == null) null else switch ([a, b]) {
            case [Left(aStr), Left(bStr)] if (aStr == bStr):
                a;
            case [Right(aFloat), Right(bFloat)] if (aFloat == bFloat):
                a;
            default:
                null;
        };
    }

    public static var areEqual = variadic(_areEqual, true);

    public static function sort<T>(a:Array<T>, ?comp:(T, T) -> Int):kiss.List<T> {
        if (comp == null)
            comp = Reflect.compare;
        var sorted = a.copy();
        sorted.sort(comp);
        return sorted;
    }

    public static function groups<T>(a:Array<T>, size, extraHandling = Drop) {
        var numFullGroups = Math.floor(a.length / size);
        var fullGroups = [
            for (num in 0...numFullGroups) {
                var start = num * size;
                var end = (num + 1) * size;
                a.slice(start, end);
            }
        ];
        if (a.length % size != 0) {
            switch (extraHandling) {
                case Throw:
                    throw 'groups was given a non-divisible number of elements: $a, $size';
                case Keep:
                    fullGroups.push(a.slice(numFullGroups * size));
                case Drop:
            }
        }

        return fullGroups;
    }

    public static function zip(arrays:Array<Array<Dynamic>>, extraHandling = Drop):kiss.List<kiss.List<Dynamic>> {
        var lengthsAreEqual = true;
        var lengths = [for (arr in arrays) arr.length];
        var lengthOperands = [for (length in lengths) Operand.fromDynamic(length)];
        for (idx in 1...lengths.length) {
            if (lengths[idx] != lengths[idx - 1]) {
                lengthsAreEqual = false;
                break;
            }
        }
        var max = Math.floor(if (!lengthsAreEqual) {
            switch (extraHandling) {
                case Throw:
                    throw 'zip was given lists of mis-matched size: $arrays';
                case Keep:
                    Operand.toDynamic(Prelude.max(lengthOperands));
                case Drop:
                    Operand.toDynamic(Prelude.min(lengthOperands));
            }
        } else {
            lengths[0];
        });

        return [
            for (idx in 0...max) {
                var zipped:Array<Dynamic> = [];

                for (arr in arrays) {
                    zipped.push(
                        if (idx < arr.length) {
                            arr[idx];
                        } else {
                            null;
                        }
                    );
                }

                zipped;
            }
        ];
    }

    public static function pairs(l:kiss.List<Dynamic>, loopAround = false):kiss.List<kiss.List<Dynamic>> {
        var l1 = l.slice(0, l.length - 1);
        var l2 = l.slice(1, l.length);
        if (loopAround) {
            l1.push(l[-1]);
            l2.unshift(l[0]);
        }
        return zip([l1, l2]);
    }

    public static function reversed<T>(l:kiss.List<T>):kiss.List<T> {
        var c = l.copy();
        c.reverse();
        return c;
    }

    // Ranges with a min, exclusive max, and step size, just like Python.
    public static function range(min, max, step):Iterator<Int> {
        if (step <= 0)
            throw "(range...) can only count up";
        var count = min;
        return {
            next: () -> {
                var oldCount = count;
                count += step;
                oldCount;
            },
            hasNext: () -> {
                count < max;
            }
        };
    }

    public static dynamic function truthy<T>(v:T) {
        return switch (Type.typeof(v)) {
            case TNull: false;
            case TBool: cast(v, Bool);
            default:
                // Empty strings are falsy
                if (v.isOfType(String)) {
                    var str:String = cast v;
                    str.length > 0;
                } else if (v.isOfType(Array)) {
                    // Empty lists are falsy
                    var lst:Array<Dynamic> = cast v;
                    lst.length > 0;
                } else {
                    // Any other value is true by default
                    true;
                };
        }
    }

    // Based on: http://old.haxe.org/doc/snip/memoize
    public static function memoize(func:Function, ?caller:Dynamic):Function {
        var argMap = new Map<String, Dynamic>();
        var f = (args:Array<Dynamic>) -> {
            var argString = args.join('|');
            return if (argMap.exists(argString)) {
                argMap[argString];
            } else {
                var ret = Reflect.callMethod(caller, func, args);
                argMap[argString] = ret;
                ret;
            };
        };
        f = Reflect.makeVarArgs(f);
        return f;
    }

    public static dynamic function print<T>(v:T):T {
        #if (sys || hxnodejs)
        Sys.println(v);
        #else
        trace(v);
        #end
        return v;
    }

    public static function symbolNameValue(s:ReaderExp):String {
        return switch (s.def) {
            case Symbol(name): name;
            default: throw 'expected $s to be a plain symbol';
        };
    }

    // ReaderExp helpers for macros:
    public static function symbol(?name:String):ReaderExpDef {
        if (name == null)
            name = '_${Uuid.v4().toShort()}';
        return Symbol(name);
    }

    public static function symbolName(s:ReaderExp):ReaderExpDef {
        return switch (s.def) {
            case Symbol(name): StrExp(name);
            default: throw 'expected $s to be a plain symbol';
        };
    }

    public static function expList(s:ReaderExp):Array<ReaderExp> {
        return switch (s.def) {
            case ListExp(exps):
                exps;
            default: throw 'expected $s to be a list expression';
        }
    }

    #if sys
    private static var kissProcess:Process = null;
    #end

    /**
     * On Sys targets and nodejs, Kiss can be converted to hscript at runtime
     * NOTE on non-nodejs targets, after the first time calling this function,
     * it will be much faster
     * NOTE on non-nodejs sys targets, newlines in raw strings will be stripped away.
     * So don't use raw string literals in Kiss you want parsed and evaluated at runtime.
     */
    public static function convertToHScript(kissStr:String):String {
        #if (!macro && hxnodejs)
        var kissProcess = ChildProcess.spawnSync("haxelib", ["run", "kiss", "convert", "--all", "--hscript"], {input: '${kissStr}\n'});
        if (kissProcess.status != 0) {
            var error:String = kissProcess.stderr;
            throw 'failed to convert ${kissStr} to hscript: ${error}';
        }
        var output:Buffer = kissProcess.stdout;
        return output.toString();
        #elseif sys
        if (kissProcess == null)
            kissProcess = new Process("haxelib", ["run", "kiss", "convert", "--hscript"]);

        kissProcess.stdin.writeString('${kissStr.replace("\n", " ")}\n');

        try {
            var output = kissProcess.stdout.readLine();
            if (output.startsWith(">>> ")) {
                output = output.substr(4);
            }
            return output;
        } catch (e) {
            var error = kissProcess.stderr.readAll().toString();
            throw 'failed to convert ${kissStr} to hscript: ${error}';
        }
        #else
        throw "Can't convert Kiss to HScript on this target.";
        #end
    }
}
