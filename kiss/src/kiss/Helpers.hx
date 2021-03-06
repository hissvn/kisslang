package kiss;

import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.PositionTools;
import hscript.Parser;
import hscript.Interp;
import kiss.Reader;
import kiss.ReaderExp;
import kiss.CompileError;
import kiss.Kiss;
import kiss.SpecialForms;
import kiss.Prelude;
import uuid.Uuid;

using uuid.Uuid;
using tink.MacroApi;
using kiss.Reader;
using kiss.Helpers;
using kiss.Kiss;
using StringTools;

/**
 * Compile-time helper functions for Kiss. Don't import or reference these at runtime.
 */
class Helpers {
    public static function macroPos(exp:ReaderExp) {
        var kissPos = exp.pos;
        return PositionTools.make({
            min: kissPos.absoluteChar,
            max: kissPos.absoluteChar,
            file: kissPos.file
        });
    }

    public static function withMacroPosOf(e:ExprDef, exp:ReaderExp):Expr {
        return {
            pos: macroPos(exp),
            expr: e
        };
    }

    static function startsWithUpperCase(s:String) {
        return s.charAt(0) == s.charAt(0).toUpperCase();
    }

    public static function parseTypePath(path:String, from:ReaderExp):TypePath {
        return switch (parseComplexType(path, from)) {
            case TPath(path):
                path;
            default:
                throw CompileError.fromExp(from, 'Haxe could not parse a type path from $path');
        };
    }

    public static function parseComplexType(path:String, from:ReaderExp):ComplexType {
        // Trick Haxe into parsing it for us:
        var typeCheckExpr = Context.parse('(thing : $path)', Context.currentPos());
        return switch (typeCheckExpr.expr) {
            case EParenthesis({pos: _, expr: ECheckType(_, complexType)}):
                complexType;
            default:
                throw CompileError.fromExp(from, 'Haxe could not parse a complex type from $path, parsed ${typeCheckExpr.expr}');
        };
    }

    public static function explicitType(nameExp:ReaderExp):ComplexType {
        return switch (nameExp.def) {
            case MetaExp(_, innerExp):
                explicitType(innerExp);
            case TypedExp(type, _):
                Helpers.parseComplexType(type, nameExp);
            default: null;
        };
    }

    public static function varName(formName:String, nameExp:ReaderExp, nameType = "variable") {
        return switch (nameExp.def) {
            case Symbol(name):
                name;
            case MetaExp(_, nameExp) | TypedExp(_, nameExp):
                varName(formName, nameExp);
            default:
                throw CompileError.fromExp(nameExp, 'The first argument to $formName should be a $nameType name, :Typed $nameType name, and/or &meta $nameType name.');
        };
    }

    // TODO generic type parameter declarations
    public static function makeFunction(?name:ReaderExp, returnsValue:Bool, argList:ReaderExp, body:List<ReaderExp>, k:KissState, formName:String):Function {
        var funcName = if (name != null) {
            varName(formName, name, "function");
        } else {
            "";
        };

        var numArgs = 0;
        // Once the &opt meta appears, all following arguments are optional until &rest
        var opt = false;
        // Once the &rest meta appears, no other arguments can be declared
        var rest = false;
        var restProcessed = false;

        function makeFuncArg(funcArg:ReaderExp):FunctionArg {
            if (restProcessed) {
                throw CompileError.fromExp(funcArg, "cannot declare more arguments after a &rest argument");
            }
            return switch (funcArg.def) {
                case MetaExp("rest", innerFuncArg):
                    if (funcName == "") {
                        throw CompileError.fromExp(funcArg, "lambda does not support &rest arguments");
                    }

                    // rest arguments define a Kiss special form with the function's name that wraps
                    // the rest args in a list when calling it from Kiss
                    k.specialForms[funcName] = (wholeExp:ReaderExp, args:Array<ReaderExp>, k:KissState) -> {
                        var realCallArgs = args.slice(0, numArgs);
                        var restArgs = args.slice(numArgs);
                        realCallArgs.push(ListExp(restArgs).withPosOf(wholeExp));
                        ECall(k.convert(Symbol(funcName).withPosOf(wholeExp)), realCallArgs.map(k.convert)).withMacroPosOf(wholeExp);
                    };

                    opt = true;
                    rest = true;
                    makeFuncArg(innerFuncArg);
                case MetaExp("opt", innerFuncArg):
                    opt = true;
                    makeFuncArg(innerFuncArg);
                default:
                    if (rest) {
                        restProcessed = true;
                    } else {
                        ++numArgs;
                    }
                    {
                        // These could use varName() and explicitType() but so far there are no &meta annotations for function arguments
                        name: switch (funcArg.def) {
                            case Symbol(name) | TypedExp(_, {pos: _, def: Symbol(name)}):
                                name;
                            default:
                                throw CompileError.fromExp(funcArg, 'function argument should be a symbol or typed symbol');
                        },
                        type: switch (funcArg.def) {
                            case TypedExp(type, _):
                                Helpers.parseComplexType(type, funcArg);
                            default: null;
                        },
                        opt: opt
                    };
            };
        }

        var expr = if (body.length == 0) {
            EReturn(null).withMacroPosOf(if (name != null) name else argList);
        } else {
            var block = k.convert(CallExp(Symbol("begin").withPos(body[0].pos), body).withPos(body[0].pos));

            if (returnsValue) {
                EReturn(block).withMacroPosOf(body[-1]);
            } else {
                block;
            };
        }

        // To make function args immutable by default, we would use (let...) instead of (begin...)
        // to make the body expression.
        // But setting null arguments to default values is so common, and arguments are not settable references,
        // so function args are not immutable.
        return {
            ret: if (name != null) Helpers.explicitType(name) else null,
            args: switch (argList.def) {
                case ListExp(funcArgs):
                    funcArgs.map(makeFuncArg);
                case CallExp(_, _):
                    throw CompileError.fromExp(argList, 'expected an argument list. Change the parens () to brackets []');
                default:
                    throw CompileError.fromExp(argList, 'expected an argument list');
            },
            expr: expr
        }
    }

    public static function makeSwitchCase(caseExp:ReaderExp, k:KissState, ?guard:Expr):Case {
        var guard:Expr = null;

        function makeSwitchPattern(patternExp:ReaderExp):Array<Expr> {
            return switch (patternExp.def) {
                case CallExp({pos: _, def: Symbol("when")}, whenExps):
                    patternExp.checkNumArgs(2, 2, "(when [guard] [pattern])");
                    if (guard != null)
                        throw CompileError.fromExp(caseExp, "case expression can only have one `when` guard");
                    guard = macro Prelude.truthy(${k.convert(whenExps[0])});
                    makeSwitchPattern(whenExps[1]);
                default:
                    [k.forCaseParsing().convert(patternExp)];
            }
        }

        return switch (caseExp.def) {
            case CallExp(patternExp, caseBodyExps):
                {
                    values: makeSwitchPattern(patternExp),
                    expr: k.convert(CallExp(Symbol("begin").withPosOf(caseExp), caseBodyExps).withPosOf(caseExp)),
                    guard: guard
                };
            default:
                throw CompileError.fromExp(caseExp, "case expressions for (case...) must take the form ([pattern] [body...])");
        }
    }

    /**
        Throw a CompileError if the given expression has the wrong number of arguments
    **/
    public static function checkNumArgs(wholeExp:ReaderExp, min:Null<Int>, max:Null<Int>, ?expectedForm:String) {
        if (expectedForm == null) {
            expectedForm = if (max == min) {
                '$min arguments';
            } else if (max == null) {
                'at least $min arguments';
            } else if (min == null) {
                'no more than $max arguments';
            } else if (min == null && max == null) {
                throw 'checkNumArgs() needs a min or a max';
            } else {
                'between $min and $max arguments';
            };
        }

        var args = switch (wholeExp.def) {
            case CallExp(_, args): args;
            default: throw CompileError.fromExp(wholeExp, "Can only check number of args in a CallExp");
        };

        if (min != null && args.length < min) {
            throw CompileError.fromExp(wholeExp, 'Not enough arguments. Expected $expectedForm');
        } else if (max != null && args.length > max) {
            throw CompileError.fromExp(wholeExp, 'Too many arguments. Expected $expectedForm');
        }
    }

    // This stack will contain multiple references to the same interp--to count how many layers deep it is.
    // This stack is like top in Inception. When empty, it proves that we're not running at compiletime yet.
    // When we ARE running at compiletime already, the pre-existing interp will be used
    static var interps:kiss.List<Interp> = [];

    public static function runAtCompileTime(exp:ReaderExp, k:KissState, ?args:Map<String, Dynamic>):ReaderExp {
        var code = k.forHScript().convert(exp).toString(); // tink_macro to the rescue
        #if test
        Prelude.print("Compile-time hscript: " + code);
        #end
        var parser = new Parser();
        if (interps.length == 0) {
            var interp = new KissInterp();
            interp.variables.set("read", Reader.assertRead.bind(_, k));
            interp.variables.set("readExpArray", Reader.readExpArray.bind(_, _, k));
            interp.variables.set("ReaderExp", ReaderExpDef);
            interp.variables.set("nextToken", Reader.nextToken.bind(_, "a token"));
            interp.variables.set("kiss", {
                ReaderExp: {
                    ReaderExpDef: ReaderExpDef
                },
                Operand: {
                    toDynamic: Operand.toDynamic,
                    fromDynamic: Operand.fromDynamic
                }
            });
            interp.variables.set("k", k.forHScript());
            interp.variables.set("Helpers", Helpers);
            interp.variables.set("Macros", Macros);
            interps.push(interp);
        } else {
            interps.push(interps[-1]);
        }
        var parsed = parser.parseString(code);

        // TODO if an internal evaluation ever needs to end before its outer evaluation is done,
        // this will cause problems because the old args will be overwritten and lost
        interps[-1].variables.set("__args__", args); // trippy
        if (args != null) {
            for (arg => value in args) {
                interps[-1].variables.set(arg, value);
            }
        }
        var value:Dynamic = if (interps.length == 1) {
            interps[-1].execute(parsed);
        } else {
            interps[-1].expr(parsed);
        };
        interps.pop();
        if (value == null) {
            throw CompileError.fromExp(exp, "compile-time evaluation returned null");
        }
        var expResult = compileTimeValueToReaderExp(value, exp);
        #if test
        Prelude.print('Compile-time value: ${Reader.toString(expResult.def)}');
        #end
        return expResult;
    }

    // The value could be either a ReaderExp, ReaderExpDef, Array of ReaderExp/ReaderExpDefs, or something else entirely,
    // but it needs to be a ReaderExp for evalUnquotes()
    static function compileTimeValueToReaderExp(e:Dynamic, source:ReaderExp):ReaderExp {
        return if (Std.isOfType(e, Array)) {
            var arr:Array<Dynamic> = e;
            var listExps = arr.map(compileTimeValueToReaderExp.bind(_, source));
            ListExp(listExps).withPosOf(source);
        } else if (e.def == null) {
            (e : ReaderExpDef).withPosOf(source);
        } else {
            (e : ReaderExp);
        }
    }

    static function evalUnquoteLists(l:Array<ReaderExp>, k:KissState, ?args:Map<String, Dynamic>):Array<ReaderExp> {
        var idx = 0;
        while (idx < l.length) {
            switch (l[idx].def) {
                case UnquoteList(exp):
                    l.splice(idx, 1);
                    var listToInsert:Dynamic = runAtCompileTime(exp, k, args);
                    // listToInsert could be either an array (from &rest) or a ListExp (from [list syntax])
                    var newElements:Array<ReaderExp> = if (Std.isOfType(listToInsert, Array)) {
                        listToInsert;
                    } else {
                        switch (listToInsert.def) {
                            case ListExp(elements):
                                elements;
                            default:
                                throw CompileError.fromExp(listToInsert, ",@ can only be used with lists");
                        };
                    };
                    for (el in newElements) {
                        l.insert(idx++, el);
                    }
                default:
                    idx++;
            }
        }
        return l;
    }

    public static function evalUnquotes(exp:ReaderExp, k:KissState, ?args:Map<String, Dynamic>):ReaderExp {
        var def = switch (exp.def) {
            case Symbol(_) | StrExp(_) | RawHaxe(_):
                exp.def;
            case CallExp(func, callArgs):
                CallExp(evalUnquotes(func, k, args), evalUnquoteLists(callArgs, k, args).map(evalUnquotes.bind(_, k, args)));
            case ListExp(elements):
                ListExp(evalUnquoteLists(elements, k, args).map(evalUnquotes.bind(_, k, args)));
            case TypedExp(type, innerExp):
                TypedExp(type, evalUnquotes(innerExp, k, args));
            case FieldExp(field, innerExp):
                FieldExp(field, evalUnquotes(innerExp, k, args));
            case KeyValueExp(keyExp, valueExp):
                KeyValueExp(evalUnquotes(keyExp, k, args), evalUnquotes(valueExp, k, args));
            case Unquote(innerExp):
                var unquoteValue:Dynamic = runAtCompileTime(innerExp, k, args);
                if (unquoteValue == null) {
                    throw CompileError.fromExp(innerExp, "unquote evaluated to null");
                } else if (Std.isOfType(unquoteValue, ReaderExpDef)) {
                    unquoteValue;
                } else if (Reflect.getProperty(unquoteValue, "def") != null) {
                    unquoteValue.def;
                } else {
                    throw CompileError.fromExp(exp, "unquote didn't evaluate to a ReaderExp or ReaderExpDef");
                };
            case MetaExp(meta, innerExp):
                MetaExp(meta, evalUnquotes(innerExp, k, args));
            default:
                throw CompileError.fromExp(exp, 'unquote evaluation not implemented');
        };
        return def.withPosOf(exp);
    }

    public static function removeTypeAnnotations(exp:ReaderExp):ReaderExp {
        var def = switch (exp.def) {
            case Symbol(_) | StrExp(_) | RawHaxe(_) | Quasiquote(_):
                exp.def;
            case CallExp(func, callArgs):
                CallExp(removeTypeAnnotations(func), callArgs.map(removeTypeAnnotations));
            case ListExp(elements):
                ListExp(elements.map(removeTypeAnnotations));
            case TypedExp(type, innerExp):
                innerExp.def;
            case MetaExp(meta, innerExp):
                MetaExp(meta, removeTypeAnnotations(innerExp));
            case FieldExp(field, innerExp):
                FieldExp(field, removeTypeAnnotations(innerExp));
            case KeyValueExp(keyExp, valueExp):
                KeyValueExp(removeTypeAnnotations(keyExp), removeTypeAnnotations(valueExp));
            default:
                throw CompileError.fromExp(exp, 'cannot remove type annotations');
        };
        return def.withPosOf(exp);
    }

    // Return convenient functions for succinctly making new ReaderExps that link back to an original exp's
    // position in source code
    public static function expBuilder(posRef:ReaderExp) {
        return {
            call: (func:ReaderExp, args:Array<ReaderExp>) -> CallExp(func, args).withPosOf(posRef),
            callSymbol: (symbol:String, args:Array<ReaderExp>) -> CallExp(Symbol(symbol).withPosOf(posRef), args).withPosOf(posRef),
            list: (exps:Array<ReaderExp>) -> ListExp(exps).withPosOf(posRef),
            str: (s:String) -> StrExp(s).withPosOf(posRef),
            symbol: (?name:String) -> Prelude.symbol(name).withPosOf(posRef),
            raw: (code:String) -> RawHaxe(code).withPosOf(posRef),
            typed: (path:String, exp:ReaderExp) -> TypedExp(path, exp).withPosOf(posRef),
            meta: (m:String, exp:ReaderExp) -> MetaExp(m, exp).withPosOf(posRef),
            field: (f:String, exp:ReaderExp) -> FieldExp(f, exp).withPosOf(posRef),
            keyValue: (key:ReaderExp, value:ReaderExp) -> KeyValueExp(key, value).withPosOf(posRef),
            opToDynamic: (operandExp:ReaderExp) -> CallExp(Symbol("kiss.Operand.toDynamic").withPosOf(posRef), [operandExp]).withPosOf(posRef),
            opFromDynamic: (operandExp:ReaderExp) -> CallExp(Symbol("kiss.Operand.fromDynamic").withPosOf(posRef), [operandExp]).withPosOf(posRef),
            begin: (exps:Array<ReaderExp>) -> CallExp(Symbol("begin").withPosOf(posRef), exps).withPosOf(posRef)
        };
    }

    public static function argList(exp:ReaderExp, forThis:String):Array<ReaderExp> {
        return switch (exp.def) {
            case ListExp(argExps):
                argExps;
            default:
                throw CompileError.fromExp(exp, '$forThis arg list should be a list expression');
        };
    }

    public static function bindingList(exp:ReaderExp, forThis:String, allowEmpty = false):Array<ReaderExp> {
        return switch (exp.def) {
            case ListExp(bindingExps) if ((allowEmpty || bindingExps.length > 0) && bindingExps.length % 2 == 0):
                bindingExps;
            default:
                throw CompileError.fromExp(exp, '$forThis bindings should be a list expression with an even number of sub expressions (at least 2)');
        };
    }
}
