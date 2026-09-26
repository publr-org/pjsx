# PJSX

PJSX compiles `.ptsx` and `.pjsx` components to specialized browser DOM code and
blocking native Zig rendering. Zig is pinned by `.zigversion`.

```sh
zig build
zig build test
zig-out/bin/pjsx dom src/Users.ptsx --out src
zig-out/bin/pjsx zig src/Users.ptsx --out src
zig-out/bin/pjsx behavior src/Users.ptsx --out src
```

`dom` emits `.js` factories importing `publr/dom` and `publr/runtime`. `zig`
emits `.zig` modules with `render`, `operations`, `dispatch` and `writeTypes`.
`zig` includes `data-p-on`, value bindings and named structural ranges.
`behavior` emits an independent `.behavior.js` companion using `publr/html`: store
actions, shared reactive values and templates for later structural updates. It
does not import or hydrate the DOM factory.
Keep generated files beside their source so relative component/backend imports
resolve. Use the same source paths for all targets: endpoint and binding identities
are generated from those paths and lexical positions. Regenerate all targets together.

See [the implemented contract](../publr-js/docs/rewrite-contract.md) for authoring,
backend signatures, host integration, ownership, hydration and diagnostics.
[Executable fixtures](../publr-js/tests/compiled) exercise actual native operations,
HTML transfer, generated browser endpoints, nested components and HTML adapters.
Run `npm run verify` in `../publr-js` after building this compiler.

The public library exports `dom.transformPjsxToDom` and `compiled.lower` for these
paths. The compiler also retains independent IR, class extraction, PHP and portable
scalar tooling; those profiles do not implement this async JSON component contract.
The prior generic `h` output and automatic module store-family rewriting are removed
from the default DOM path. Explicit `dom-zig` and `dom-behavior` commands retain the older DOM-adoption
output for compatibility tests; ordinary SSR uses `zig` and `behavior`.

Native modules use named `.zig` imports. Their actual Zig function types generate
TypeScript declarations through `writeTypes`; write each result beside the native
module as `name.d.zig.ts` before checking PTSX. No browser engine or JavaScript
backend implementation is required by SSR.

Type checking resolves the sibling `publr-js` source by default. `PUBLR_JS_ROOT`
can override its location. The compiler itself remains pure Zig; TypeScript and
Playwright are development dependencies.
