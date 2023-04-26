## WARNING:
## This file needs to be included and cannot be imported. Otherwise the C++ emitted
## types are not available in the calling scope. :(
## Otherwise:
#[
CC: train_ingrid.nim
/home/basti/.cache/nim/train_ingrid_r/@mtrain_ingrid.nim.cpp:470:25: error: 'MLPImpl' was not declared in this scope
  470 | typedef std::shared_ptr<MLPImpl>  TY__2pAqwDbe669bAzOuOuBbWug;
      |                         ^~~~~~~
compilation terminated due to -Wfatal-errors.
Error: execution of an external compiler program 'g++ -c -std=gnu++17 -funsigned-char  -w -fmax-errors=3 -fpermissive -pthread -I/home/basti/CastData/ExternC
ode/flambeau/vendor/libtorch/include -I/home/basti/CastData/ExternCode/flambeau/vendor/libtorch/include/torch/csrc/api/include -Wfatal-errors -O3 -fno-strict
-aliasing -fno-ident -fno-math-errno   -I/home/basti/src/nim/nim_git_repo/lib -I/home/basti/CastData/ExternCode/TimepixAnalysis/Tools/NN_playground -o /home/
basti/.cache/nim/train_ingrid_r/@mtrain_ingrid.nim.cpp.o /home/basti/.cache/nim/train_ingrid_r/@mtrain_ingrid.nim.cpp' failed with exit code: 1

]#

# Update: to circumvent the above we define a custom C++ header file from which we define the type instead

import flambeau / [flambeau_nn]
import ingrid / [tos_helpers, ingrid_types]

type
  MLPImpl* {.pure, header: "mlp_impl.hpp", importcpp: "MLPImpl".} = object of Module
    hidden*: Linear
    hidden2*: Linear
    classifier*: Linear

  MLP* = CppSharedPtr[MLPImpl]

  ActivationFunction* = enum
    afReLU, afTanh, afELU, afGeLU # , ...?

  OutputActivation* = enum
    ofLinear, ofSigmoid, ofTanh # , ...?

  LossFunction* = enum
    lfSigmoidCrossEntropy, lfMLEloss, lfL1Loss # , ...?

  OptimizerKind* = enum
    opNone, opSGD, opAdam, opAdamW # , opAdaGrad, opAdaBoost ?

  ## A helper object that describes the layers of an MLP
  ## The number of input neurons and neurons on the hidden layer.
  ## This is serialized as an H5 file next to the trained network checkpoints.
  ## On loading a network this file is parsed first and then used to initialize
  ## the correct size of a network.
  ## In addition it contains the datasets that are used for the input.
  MLPDesc* = object
    path*: string # model path to the checkpoint files including the default model name!
    plotPath*: string # path in which plots are placed
    calibFiles*: seq[string] ## Path to the calibration files
    backFiles*: seq[string] ## Path to the background data files
    simulatedData*: bool
    numInputs*: int
    numHidden*: seq[int]
    numLayers*: int
    learningRate*: float
    datasets*: seq[string] # Not `InGridDsetKind` to support arbitrary new columns
    subsetPerRun*: int
    rngSeed*: int
    #
    activationFunction*: ActivationFunction
    outputActivation*: OutputActivation
    lossFunction*: LossFunction
    optimizer*: OptimizerKind
    # fields that store training information
    epochs*: seq[int] ## epochs at which plots and checkpoints are generated
    accuracies*: seq[float]
    testAccuracies*: seq[float]
    losses*: seq[float]
    testLosses*: seq[float]

  ## Old `MLPDesc` object. It is kept around to be above to deserialize the
  ## old files easily and then map them to the new object (and thus rewrite the file).
  ## We test for whether a file is V1 by checking for `numHidden` as an attribute. If
  ## no such attribute exists the file is a V2 file.
  MLPDescV1* = object
    path*: string # model path to the checkpoint files including the default model name!
    plotPath*: string # path in which plots are placed
    numInputs*: int
    numHidden*: int
    learningRate*: float
    datasets*: seq[string] # Not `InGridDsetKind` to support arbitrary new columns
    # fields that store training information
    epochs*: seq[int] ## epochs at which plots and checkpoints are generated
    accuracies*: seq[float]
    testAccuracies*: seq[float]
    losses*: seq[float]
    testLosses*: seq[float]

  ModelKind* = enum
    mkMLP = "MLP"
    mkCNN = "ConvNet"

  ## Placeholder for `ConvNet` above as currently defining both is problematic
  ConvNet* = object

  AnyModel* = MLP | ConvNet

## The batch size we use!
const bsz = 8192 # batch size


const MLPDescName* = "mlp_desc.h5"
proc initMLPDesc*(calib, back, datasets: seq[string],
                  modelPath: string, plotPath: string,
                  numHidden: seq[int],
                  activation: ActivationFunction,
                  outputActivation: OutputActivation,
                  lossFunction: LossFunction,
                  optimizer: OptimizerKind,
                  learningRate: float,
                  subsetPerRun: int,
                  simulatedData: bool,
                  rngSeed: int): MLPDesc =
  result = MLPDesc(calibFiles: calib,
                   backFiles: back,
                   datasets: datasets,
                   path: modelPath, plotPath: plotPath,
                   numInputs: datasets.len,
                   numHidden: numHidden,
                   numLayers: numHidden.len,
                   activationFunction: activation,
                   outputActivation: outputActivation,
                   lossFunction: lossFunction,
                   optimizer: optimizer,
                   learningRate: learningRate,
                   subsetPerRun: subsetPerRun,
                   simulatedData: simulatedData,
                   rngSeed: rngSeed)

proc init*(T: type MLP): MLP =
  result = make_shared(MLPImpl)
  result.hidden = result.register_module("hidden_module", init(Linear, 13, 500))
  result.hidden2 = result.register_module("hidden2_module", init(Linear, 13, 500))
  result.classifier = result.register_module("classifier_module",
      init(Linear, 500, 2))

proc forward*(net: MLP, desc: MLPDesc, x: RawTensor): RawTensor =
  template actFn(it: typed, desc: MLPDesc): untyped =
    case desc.activationFunction
    of afReLU: it.relu()
    of afTanh: it.tanh()
    of afELU : it.elu()
    of afGeLU: it.gelu()
  template outFn(it: typed, desc: MlpDesc): untyped =
    case desc.outputActivation
    of ofLinear: it
    of ofSigmoid: it.sigmoid()
    of ofTanh: it.tanh()
  var x = net.hidden.forward(x).actFn(desc)
  if desc.numLayers == 2: # also apply layer 2
    x = net.hidden2.forward(x).actFn(desc)
  return net.classifier.forward(x).outFn(desc) #.squeeze(1)

proc init*(T: type MLP, numInput: int, numLayers: int, numHidden: seq[int], numOutput = 2): MLP =
  result = make_shared(MLPImpl)
  if numLayers != numHidden.len:
    raise newException(ValueError, "Number of layers does not match number of neurons given for each " &
      "hidden layer! Layers: " & $numLayers & " and neurons per layer: " & $numHidden)
  if numLayers > 2:
    raise newException(ValueError, "Only up to 2 hidden layers supported with the `MLPImpl` type.")
  result.hidden = result.register_module("hidden_module", init(Linear, numInput, numHidden[0]))
  if numLayers == 1: # single hidden layer MLP
    result.classifier = result.register_module("classifier_module", init(Linear, numHidden[0], numOutput))
  else: # dual hidden layer MLP
    result.hidden2 = result.register_module("hidden2_module", init(Linear, numHidden[0], numHidden[1]))
    result.classifier = result.register_module("classifier_module", init(Linear, numHidden[1], numOutput))

proc init*(T: type MLP, desc: MLPDesc): MLP =
  result = MLP.init(desc.numInputs, desc.numLayers, desc.numHidden)

from pkg / nimhdf5 import deserializeH5
from std / strutils import startsWith, parseEnum
proc initMLPDesc*(modelPath: string, plotPath = ""): MLPDesc =
  ## Initialize the `MLPDesc` from the serialized `MLPDesc` in the given
  ## `modelPath`.
  let fname = modelPath.parentDir / MLPDescName
  result = deserializeH5[MLPDesc](fname)
  if result.numHidden.len == 0:
    raise newException(IOError, "The MLPDesc H5 file is still of version 1. Please regenerate " &
      "it by running `train_ingrid` with all paramaters again.")
  if result.datasets.anyIt(it.startsWith("ig")):
    result.datasets = result.datasets.mapIt(parseEnum[InGridDsetKind](it).toDset())
  if plotPath.len > 0: # user wants a different plot path for prediction
    result.plotPath = plotPath

## XXX: Defining two models in a single file is currently broken. When trying to use it
## the nim compiler assigns the wrong destructor to the second one (reusing the one
## from the first type). This breaks it. To use it, we currently need to replace
## the logic instead (putting this one first). Once things work we can try to ask Hugo &
## check if submoduling individual models helps.
#defModule:
#  type
#    ConvNet* = object of Module
#      conv1* = Conv2d(1, 50, 15)
#      conv2* = Conv2d(50, 70, 15)
#      conv3* = Conv2d(70, 100, 15)
#      #lin1* = Linear(100 * 15 * 15, 1000)
#      lin1* = Linear(3610, 1000)
#      lin2* = Linear(1000, 50)
#      lin3* = Linear(50, 2)
#
#proc forward(net: ConvNet, x: RawTensor): RawTensor =
#  var x = net.conv1.forward(x).relu().max_pool2d([2, 2])
#  x = net.conv2.forward(x).relu().max_pool2d([2, 2])
#  x = net.conv3.forward(x).relu().max_pool2d([2, 2])
#  x = net.lin1.forward(x).relu()
#  x = net.lin2.forward(x).relu()
#  x = net.lin3.forward(x).relu()
#  return x

proc predictSingle*(model: MLP, input: RawTensor, device: Device, desc: MLPDesc): float =
  # predict the output for the single input event
  no_grad_mode:
    # Running input through the network, get the 0th neuron output
    result = model.forward(desc, input.to(device))[_, 0].item(float)

from ./io_helpers import toNimSeq
proc forward*(model: AnyModel,
              input: RawTensor,
              device: Device,
              desc: MLPDesc,
              neuron = 0): seq[float] =
  ## Returns the predictions for all input data contained in `input`
  let dataset_size = input.size(0)
  result = newSeqOfCap[float](dataset_size)
  no_grad_mode:
    for batch_id in 0 ..< (dataset_size.float / bsz.float).ceil.int:
      # minibatch offset in the Tensor
      let offset = batch_id * bsz
      let stop = min(offset + bsz, dataset_size)
      let x = input[offset ..< stop, _ ].to(device)
      # Running input through the network
      let output = model.forward(desc, x)
      result.add output[_, neuron].toNimSeq[:float]

proc modelPredict*(model: AnyModel,
                   input: RawTensor,
                   device: Device,
                   desc: MLPDesc): seq[int] =
  ## Returns the predictions for all input data contained in `input`
  let dataset_size = input.size(0)
  result = newSeqOfCap[float](dataset_size)
  no_grad_mode:
    for batch_id in 0 ..< (dataset_size.float / bsz.float).ceil.int:
      # minibatch offset in the Tensor
      let offset = batch_id * bsz
      let stop = min(offset + bsz, dataset_size)
      let x = input[offset ..< stop, _ ].to(device)
      # Running input through the network
      let output = model.forward(desc, x)
      let pred = output.argmax(1).toNimSeq[:int]()
      result.add pred
