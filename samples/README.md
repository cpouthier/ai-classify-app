# Sample images

30 real, recognizable photos (animals, everyday objects, vehicles, landscapes) covering a range
of ImageNet-1000 classes, plus three synthetic placeholder PNGs (flat-color shapes) kept around
for quick pipeline smoke-testing, a shape on a plain background won't match any real class
meaningfully, so don't expect a convincing label from those three.

These are baked into the app image and seeded into the `<release>-trainingdata` PVC on first
boot, the app's "Classify sample" picker lets you run one through the model with a click, no
need to have your own test images on hand.
