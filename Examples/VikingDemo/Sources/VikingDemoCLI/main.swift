import Foundation
import VikingDemoCore

// Headless twin of the SwiftUI demo, for scripted verification of the
// Phase 5 acceptance criterion (Viking.start -> event visible in Live
// Events). Exercises the exact same DemoRunner - and therefore the
// exact same Viking SDK calls - with no window/GUI dependency, so it
// runs in CI or a background shell.
let runner = DemoRunner()
await runner.runAutomatically()
