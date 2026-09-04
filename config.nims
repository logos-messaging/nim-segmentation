# The package's import root is its srcDir ("segmentation"), where the API module
# segmentation.nim lives. Put it on the path so in-repo consumers (tests/)
# resolve `import segmentation` the same way nimble consumers of the package do.
switch("path", thisDir() & "/segmentation")

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
