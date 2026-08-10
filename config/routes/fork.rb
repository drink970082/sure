# Fork-only routes.
#
# Everything this fork adds on top of we-promise/sure goes here rather than in
# config/routes.rb. Upstream has no config/routes/ directory, so this file can
# never conflict during a rebase; config/routes.rb only carries the single
# `draw(:fork)` line at the end of its block.
#
# Loaded by `draw(:fork)` and evaluated inside the router, so write plain route
# declarations - no surrounding `Rails.application.routes.draw` block.
