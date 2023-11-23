import os, nimhdf5, datamancer, strutils, sugar, sequtils, stats
import ingrid / ingrid_types

#[
This is a companion tool to `TimepixAnalysis/Analysis/runLimits.nim`.

Given the path to where the former outputs the log and H5 files to, this script reads
all files from the path and generates an Org table of the different setups and their
respective expected limits.
]#

type
  LimitData = object
    expectedLimit: float
    expLimitVariance: float
    expLimitStd: float
    limitNoSignal: float
    vetoes: set[LogLFlagKind]
    eff: Efficiency

  Efficiency = object
    totalEff: float # total efficiency multiplier based on signal efficiency of lnL cut, FADC & veto random coinc rate
    signalEff: float # the lnL cut signal efficiency used in the inputs
    nnSignalEff: float # target signal efficiency of MLP
    nnEffectiveEff: float # effective efficiency based on
    nnEffectiveEffStd: float
    eccLineVetoCut: float # the eccentricity cutoff for the line veto (affects random coinc.)
    vetoPercentile: float # if FADC veto used, the percentile used to generate the cuts
    septemVetoRandomCoinc: float # random coincidence rate of septem veto
    lineVetoRandomCoinc: float # random coincidence rate of line veto
    septemLineVetoRandomCoinc: float # random coincidence rate of septem + line veto

proc expLimit(limits: seq[float]): float =
  result = sqrt(limits.percentile(50)) * 1e-12


import random

template withBootstrap(rnd: var Rand, samples: seq[float], num: int, body: untyped): untyped =
  let N = samples.len
  for i in 0 ..< num:
    # resample
    var newSamples {.inject.} = newSeq[float](N)
    for j in 0 ..< N:
      newSamples[j] = samples[rnd.rand(0 ..< N)] # get an index and take its value
    # compute our statistics
    body

proc expLimitVarStd(limits: seq[float]): (float, float) =
  var rnd = initRand(12312)
  let limits = limits.mapIt(sqrt(it) * 1e-12) # rescale limits
  const num = 1000
  var medians = newSeqOfCap[float](num)
  withBootstrap(rnd, limits, num):
    medians.add median(newSamples, 50)
  #echo "Medians? ", medians
  result = (variance(medians), standardDeviation(medians))

proc readVetoes(h5f: H5File): set[LogLFlagKind] =
  let flags = h5f["/ctx/logLFlags", string]
  for f in flags:
    result.incl parseEnum[LogLFlagKind](f)

import std / strscans
proc tryParseEccLine(s: string): float =
  let (success, _, val) = scanTuple(s, "$*_eccCutoff_$f")
  if success:
    result = val

proc readEfficiencies(h5f: H5File): Efficiency =
  let eff = h5f["/ctx/eff".grp_str]
  if "eccLineVetoCut" in eff.attrs:
    result = h5f.deserializeH5[:Efficiency](eff.name)
  else:
    result = h5f.deserializeH5[:Efficiency](eff.name, exclude = @["eccLineVetoCut"])
    result.eccLineVetoCut = tryParseEccLine(h5f.name)

proc readLimit(fname: string): LimitData =
  var h5f = H5open(fname, "r")
  let limits = h5f["/limits", float]
  let noCands = h5f.attrs["limitNoSignal", float]
  let vetoes = readVetoes(h5f)
  let effs = readEfficiencies(h5f)
  let (variance, std) = expLimitVarStd(limits)
  result = LimitData(expectedLimit: expLimit(limits),
                     expLimitVariance: variance,
                     expLimitStd: std,
                     limitNoSignal: sqrt(noCands) * 1e-12,
                     vetoes: vetoes,
                     eff: effs)

proc asDf(limit: LimitData): DataFrame =
  ## Calling it `toDf` causes issues...
  let typ = if fkMLP in limit.vetoes: "MLP"
             else: "LnL"
  let eff = if fkMLP in limit.vetoes: limit.eff.nnEffectiveEff
            else: limit.eff.signalEff
  let septem = fkSeptem in limit.vetoes
  let line = fkLineVeto in limit.vetoes
  let fadc = fkFadc in limit.vetoes
  result = toDf({ "ε_eff" : eff,
                  "Type" : typ,
                  "Scinti" : fkScinti in limit.vetoes,
                  "FADC" : fadc,
                  "ε_FADC" : 1.0 - (1.0 - limit.eff.vetoPercentile) * 2.0,
                  "Septem" : septem,
                  "Line" : line,
                  "eccLineCut" : limit.eff.eccLineVetoCut,
                  "ε_Septem" : if septem and not line: limit.eff.septemVetoRandomCoinc else: 1.0,
                  "ε_Line" : if line and not septem: limit.eff.lineVetoRandomCoinc else: 1.0,
                  "ε_SeptemLine" : if septem and line: limit.eff.septemLineVetoRandomCoinc else: 1.0,
                  "ε_total" : limit.eff.totalEff,
                  "Limit no signal [GeV⁻¹]" : limit.limitNoSignal,
                  "Expected limit [GeV⁻¹]" : limit.expectedLimit,
                  "Exp. limit variance [GeV⁻²]" : limit.expLimitVariance,
                  "Exp. limit σ [GeV⁻¹]" : limit.expLimitStd })

proc main(path: seq[string] = @[],
          prefix: seq[string] = @[]) =
  var df = newDataFrame()
  doAssert path.len == prefix.len, "Need one prefix for each path!"
  for i, p in path:
    let pref = prefix[i]
    for f in walkDirRec(p):
      let fname = extractFilename(f)
      if fname.startsWith(pref) and fname.endsWith(".h5"):
        echo "File: ", fname
        let limit = readLimit(f)
        df.add asDf(limit)
  echo df.arrange("Expected limit [GeV⁻¹]").toOrgTable(precision = 4)

when isMainModule:
  import cligen
  dispatch main
