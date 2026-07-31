// Direct entry point for the compiled backend-py, bypassing `spago run`.
//
// The corpus harness invokes the backend once per test (347 of them), and
// spago's workspace check dominates that. Importing the built output keeps
// argv in the shape Main expects (node, script, ...args).
import { main } from './output/Main/index.js'
main()
