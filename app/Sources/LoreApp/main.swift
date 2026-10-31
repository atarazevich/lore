// Executable entry point. LoreRootApp lives in the LoreKit library target,
// which cannot host the app entry. Single-bootstrap invariant: see
// LoreRootApp.sharedContext.
import LoreKit

// `Lore --check-grants` (#300): onboarding's fresh-process grant reading
// answers and exits here, before any of the app exists.
GrantCheck.runIfRequested()

LoreRootApp.main()
