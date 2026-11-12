# Block diagrams

Each RTL module has an SVG diagram embedded in its matching `docs/rtl/` page.
The root README retains `router_microarchitecture.svg` as its first image.
`router_top.svg` provides the module-level connection overview in the architecture
guide and router documentation.

Editable Graphviz sources live in `src/`. Regenerate a diagram with Graphviz:

```bash
dot -Tsvg docs/images/src/router_top.dot -o docs/images/router_top.svg
```

Run that command from the repository root, substituting the module name.
Solid arrows represent data or direct signal flow; dashed arrows represent
control and credit paths. Grouped instances such as `noc_input_port ×5`
represent replicated hardware, not a single shared port. The mesh drawing is
a 2×2 example of the parameterized array, with LOCAL interfaces shown once
for readability; every tile has its own LOCAL interfaces.

`router_microarchitecture.svg` is the earlier overview retained for reference.
The module-named diagrams describe the current dynamic-VA implementation using
rectangular blocks and orthogonal connectors.
