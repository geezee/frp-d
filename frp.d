module frp;

import std.stdio;

import std.string;

struct UniqQueue(T) {
    private bool[T] set;
    private T[] contents = [];

    public void push(T e) {
        if ((e in set) !is null) return;
        contents ~= e;
        set[e] = true;
    }

    public T pop() {
        T e = contents[0];
        contents = contents[1..$];
        set.remove(e);
        return e;
    }

    public ulong length() { return contents.length; }
}

interface HasUpdater {
    void updater();
    HasUpdater[] getDependencies();
}

class _Event(T, A...) : HasUpdater {

    private T value;
    private T delegate() new_value;

    private HasUpdater[] event_deps = [];

    alias Observer = void delegate(T);
    private Observer[] observers = [];

    this(T first) {
        value = first;
    }

    // the second argument is a function, not a delegate, because we want the
    // user to explicitly give us the closure so we can attach observers to the
    // events in said closure
    this(A a, T function(A) expr) {
        value = expr(a);
        new_value = () { return expr(a); };

        import std.traits : isInstanceOf, TemplateOf, PointerTarget, isPointer;

        alias Me = TemplateOf!_Event;

        static foreach (e; a) {
            static if (isInstanceOf!(Me, typeof(e))) {
                e.event_deps ~= this;
            }
        }
    }

    void updater() {
        if (new_value is null) return;
        value = new_value();
        foreach (o; observers) o(value);
    }

    HasUpdater[] getDependencies() {
        return event_deps;
    }

    T now() { return value; }

    T opCall() { return value; }
    typeof(this) opCall(T v) { return fire(v); }

    typeof(this) fire(T v) {
        value = v;
        foreach (o; observers) o(value);

        auto queue = UniqQueue!HasUpdater();
        foreach (dep; event_deps) {
            queue.push(dep);
        }
        while (queue.length > 0) {
            auto e = queue.pop();
            e.updater();
            foreach (dep; e.getDependencies) {
                queue.push(dep);
            }
        }

        return this;
    }

    typeof(this) transform(T delegate(T) f) {
        return fire(f(now));
    }

    void observe(Observer o) { observers ~= o; }
}

auto ref event(T)(T v) { return new _Event!T(v); }
auto ref event(string code)() { return REvent!code; }
auto ref revent(T,A...)(A a, T function(A) expr) { return new _Event!(T,A)(a, expr); }


string[] __naive_lexer_for_identifiers(string code) {
    string[] identifiers = [];
    string id = "";

    void add_identifier() { if (id.length > 0) identifiers ~= id; id = ""; }

    // used for ignoring contents of naive strings
    char stringquote = '\0';

    // doesnt cover the whole range, see ISO/IEC 9899:1999(E) Appendix D
    bool __valid_identifier_start(char c) {
        return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    bool __valid_identifier_char(char c) {
        return __valid_identifier_start(c) || (c >= '0' && c <= '9');
    }

    foreach (i, c; code) {
        if (stringquote == '"' || stringquote == '`') {
            if (c == stringquote && !(i > 0 && code[i-1] == '\\')) {
                stringquote = '\0';
            }
        } else if (c == '"' || c == '`' || c == '\'') {
            add_identifier();
            stringquote = c;
        } else {
            if (id.length == 0) {
                if (__valid_identifier_start(c)) id ~= c;
            } else if (__valid_identifier_char(c)) {
                id ~= c;
            } else add_identifier();
        }
    }

    add_identifier();
    return identifiers;
}

string __strip_d_comments(string code) {
    string result = "";
    ushort state = 0; // 0=no comment, 1=line, 2=block
    char c_char = '\0';
    char prev = '\0';
    foreach (char c; code) {
        if (state == 0) {
            if (c == '/' && prev == '/') {
                state = 1;
                result = result[0..$-1];
            } else if ((c == '*' || c == '+') && prev == '/') {
                state = 2;
                c_char = c;
                result = result[0..$-1];
            } else result ~= c;
        } else if (state == 1) {
            if (c == '\n') { state = 0; result ~= c; }
        } else if (state == 2) {
            if (prev == c_char && c == '/') { c_char = '\0'; state = 0; }
        }
        prev = c;
    }
    return result;
}


// a ton of magic happening here:
// the output is code (string) that analyses the input code
// which in turn generates the code (string) to create the Event
template REvent(string code) {
    enum REvent = q{
        /* there are two mixins here because there are two levels of code
         * generation:
         * 1. the first string generated is the code analysis that should be
         *    performed at the call site which itself generates
         * 2. the second string that is the call to the `revent` template with
         *    the free variables and the provided `code`
        */
        mixin(mixin(q{
            (() {
             enum code = "$code";

             bool[string] free_vars; // shitty way of making a ctfe set

             // collect all the free variables
             static foreach (t; code.__naive_lexer_for_identifiers) {
                import std.traits;
                // hack to know if an id is already defined at the call site
                // and is not a keyword like `for` or `import`
                static if (__traits(compiles, mixin(t))
                        // functions are fine, they already have a fixed address
                        && !isFunction!(mixin(t))
                        // types can't be passed as arguments obviously
                        && !isType!(mixin(t))
                        // to see if the code doesn't redefine the identifier and cause shadowing issues
                        && __traits(compiles, mixin("(", typeof(mixin(t)).stringof, " ", t, "){", code, "}"))
                        ) {
                            free_vars[t] = true;
                        }
             }

             // create a comma-seperated list of free variables (and their types)
             string cs_fv = "", cs_tfv = "";
             foreach (fv,_; free_vars) {
                cs_fv ~= fv ~ ",";
                cs_tfv ~= ", typeof(" ~ fv ~ ")";
             }
             // the return type of the provided expression
             string return_type = typeof(mixin("(() {", code, "})()")).stringof;

             // create the new code for creating an event
             string new_code
                 = "revent!(" ~ return_type ~ cs_tfv ~ ")(" ~ cs_fv
                 ~ "(" ~ (cs_fv.length > 0 ? cs_fv[0..$-1] : cs_fv) ~ ") {"
                 ~ code ~ " })";

             return new_code;
            })()
        }
        ))
    }.replace("$code", code.__strip_d_comments.replace("\"", "\\\""));
}
