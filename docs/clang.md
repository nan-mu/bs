clang -fsyntax-only -ferror-limit=0 -Wimplicit-function-declaration verifier.c 2>&1 | rg -o "'enum (.+)'" -r '$1'  | sort | uniq
clang -fsyntax-only -ferror-limit=0 -Wimplicit-function-declaration verifier.c 2>&1 | rg -o "error: call to undeclared function '(.+)';" -r '$1' | sort | uniq
clang -fsyntax-only -ferror-limit=0 verifier.c 2>&1 | rg -o "incomplete definition of type 'struct (.+)'" -r '$1' | sort | uniq
clang -fsyntax-only -ferror-limit=0 verifier.c 2>&1 | rg -o "unknown type name '(.+)'" -r '$1' | sort | uniq

type:
```shell
clang -fsyntax-only -ferror-limit=0 -include include/bpf_jit.h -include include/bpf_common.h bpf_jit_comp32.c 2>&1 | rg -o "unknown type name '(.+)'" -r '$1' | sort | uniq
```

struct:
```shell
clang -fsyntax-only -ferror-limit=0 -include include/bpf_jit.h -include include/bpf_common.h bpf_jit_comp32.c 2>&1 | rg -o "struct (.+)" -r '$1' | sort | uniq
```

function: 

```shell
clang -fsyntax-only -ferror-limit=0 -Wimplicit-function-declaration -include include/bpf_jit.h -include include/bpf_common.h bpf_jit_comp32.c 2>&1 | rg -o "error: call to undeclared function '(.+)';" -r '$1' | sort | uniq
```