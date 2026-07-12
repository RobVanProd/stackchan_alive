# Local Vision Models

`face_detection_yunet_2023mar.onnx` is the OpenCV Zoo YuNet face detector used by
`bridge/vision_service.py`.

- Source: https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet
- Exact download: https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
- SHA-256: `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`
- Size: `232589` bytes
- Model-directory license: MIT, as stated by the upstream OpenCV Zoo YuNet README
- Verbatim model-directory license: `LICENSE`

The worker verifies this hash before loading the model. YuNet performs face detection only;
it does not identify a person or create a face-recognition embedding. Camera frames and
detection results remain on the local robot/host link.
