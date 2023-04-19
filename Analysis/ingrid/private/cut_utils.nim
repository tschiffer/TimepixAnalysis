import std / [os, sequtils]
import pkg / [nimhdf5, ggplotnim]
from algorithm import lowerBound

import ../ingrid_types
from ./geometry import inRegion

## XXX: replace at some point by handling this manually!
converter toGenericCut*(x: tuple[dset: string, lower, upper: float]): GenericCut =
  result = GenericCut(dset: x.dset, min: x.lower, max: x.upper,
                      inverted: false)

converter toGenericCut*(x: varargs[tuple[dset: string, lower, upper: float]]): seq[GenericCut] =
  for el in x:
    result.add el.toGenericCut()

proc cutOnProperties*(h5f: H5File,
                      group: H5Group,
                      region: ChipRegion,
                      cuts: varargs[GenericCut]): seq[int] =
  ## applies the cuts from `cuts` and returns a sequence of indices, which pass
  ## the cut.
  ## Any datasets given will be converted to float after reading.
  ## For usage with FADC data, be careful to extract the event numbers using the
  ## indices first, before applying the indices on InGrid data.
  # first get data
  var dsets = newSeqOfCap[seq[float]](cuts.len)
  # for the chip data we always need the event number information!
  var dfChip = toDf({"eventNumber" : h5f.readAs(group.name / "eventNumber", int)})
  var dfFadc = newDataFrame()
  for c in cuts:
    if c.isFadc:
      let fadcGrp = group.name.parentDir / "fadc"
      if fadcGrp in h5f:
        if dfFadc.len == 0:
          dfFadc = toDf({"eventNumber" : h5f.readAs(fadcGrp / "eventNumber", int)})
        dfFadc[c.dset] = h5f.readAs(group.name.parentDir / c.dset, float)
      else:
        # if we _have_ an FADC group, but no FADC data, return empty seq as we filter _everything_
        return @[]
    else:
      dfChip[c.dset] = h5f.readAs(group.name / c.dset, float)

  ## XXX: this restritcs usage to only chips, but not only FADC!!!
  dfChip["Index"] = toSeq(0 ..< dfChip.len)

  proc toDsets(df: DataFrame, cuts: seq[GenericCut]): seq[seq[float]] =
    for c in cuts:
      result.add df[c.dset, float].toSeq1d

  ## XXX: current problem: the inner join removes data, but we want to return the
  ## INDICES. Therefore need indices in input.
  ## FIXED WITH INDEX, but currently hardcoded for dfChip
  var index: Tensor[int]
  if dfChip.len > 0 and dfFadc.len > 0:
    let dfComb = innerJoin(dfChip, dfFadc, by = "eventNumber")
    dsets = dfComb.toDsets(@cuts)
    index = dfComb["Index", int]
  elif dfChip.len > 0:
    dsets = dfChip.toDsets(@cuts)
    index = dfChip["Index", int]
  else:
    doAssert false, "This should never happen!"
    dsets = dfFadc.toDsets(@cuts)
    index = dfFadc["Index", int] ##XXX: BROKEN AT THE MOMENT!!!

  # if chip region not all, get `posX` and `posY`
  var
    posX: seq[float]
    posY: seq[float]
  case region
  of crAll:
    discard
  else:
    try:
      # TODO: this is a workaround for now. `centerX` is the name used for
      # TimepixAnalysis, but the `calibration-cdl.h5` data from Marlin uses
      # PositionX. I don't want to add a `year` field or something to this proc,
      # so for now we just depend on an exception.
      posX = h5f.readAs(group.name / "centerX", float)
      posY = h5f.readAs(group.name / "centerY", float)
    except KeyError:
      posX = h5f.readAs(group.name / "PositionX", float)
      posY = h5f.readAs(group.name / "PositionY", float)

  # take any sequence for number of events, since all need to be of the same
  # type regardless
  let nEvents = if dsets.len > 0: dsets[0].len
                elif posX.len > 0: posX.len
                else: 0
  doAssert nEvents == index.len
  doAssert nEvents > 0, "crAll cannot be combined with no `cuts`"
  for i in 0 ..< nEvents:
    # cut on region if applicable
    let idx = index[i]
    if region != crAll and not inRegion(posX[i], posY[i], region):
      continue
    var skipThis = false
    for j in 0 ..< cuts.len:
      let
        el = cuts[j]
      let
        d = dsets[j][i]
      if not el.inverted:
        if d < el.min or d > el.max:
          skipThis = true
          break
      else: # if inverted, remove everything *inside* the cut
        if d > el.min and d < el.max:
          skipThis = true
          break
    if not skipThis:
      # else add this index
      result.add idx

proc cutOnProperties*(h5f: H5File,
                      group: H5Group,
                      cuts: varargs[tuple[dset: string,
                                          lower, upper: float]],): seq[int] {.inline.} =
  ## wrapper around the above for the case of the whole chip as region
  result = h5f.cutOnProperties(group, crAll, cuts.toGenericCut())

proc cutOnProperties*(h5f: H5File,
                      group: H5Group,
                      cuts: seq[tuple[dset: string,
                                      lower, upper: float]]): seq[int] {.inline.} =
  result = h5f.cutOnProperties(group, crAll, cuts.toGenericCut())

from ./cdl_cuts import toRefDset
## Extensions for the `CutValueInterpolator` type
proc `[]`*(cv: CutValueInterpolator, e: float): float =
  case cv.cutMethod
  of cmLnLCut:
    case cv.morphKind
    of mkNone: result = cv[e.toRefDset()]
    of mkLinear:
      let idx = min(cv.lnLCutEnergies.lowerBound(e), cv.lnLCutEnergies.high)
      result = cv.lnLCutValues[idx]
  of cmNnCut:
    case cv.nnCutKind
    of nkGlobal: result = cv.cut
    of nkLocal: result = cv[e.toRefDset()]
    of nkInterpolated:
      discard
      #let idx = min(cv.nnCutEnergies.lowerBound(e), cv.nnCutEnergies.high)
      #result = cv.nnCutValues[idx]
    else:
      doAssert false, "Should not happen!"

import ./cdl_cuts, ./hdf5_utils
proc cutXrayCleaning*(df: DataFrame, tfKind: TargetFilterKind,
                      eLow = NegInf, eHigh = Inf, energyDset = igEnergyFromCharge): DataFrame =
  ## The input data frame must contain the following datasets:
  ## - `[igCenterX, igCenterY, igRmsTransverse, igLength, igEccentricity]`
  ## and optionally `igEnergyFromCharge` if `eLow` and/or `eHigh` is given.
  ## Energies eLow and eHigh can be given to
  const xrayCutsTab = getXrayCleaningCutArray()
  const requiredDsets = [igCenterX, igCenterY, igRmsTransverse, igLength, igEccentricity]
  for dset in requiredDsets:
    doAssert dset.toDset() in df, "Dataset " & $dset & " does not exist in input data frame, but is required."
  var needEnergy = false
  if eLow > NegInf or eHigh < Inf:
    needEnergy = true
    doAssert energyDset.toDset() in df, "Dataset igEnergyFromCharge does not exist in input data frame, but is required."
  let xrayCuts = xrayCutsTab[tfKind]
  let minRms = xrayCuts.minRms
  let maxRms = xrayCuts.maxRms
  let maxLen = xrayCuts.maxLength
  let maxEcc = xrayCuts.maxEccentricity
  let minPix = xrayCuts.minPix
  if not needEnergy:
    result = df.filter(f{float -> bool: (
      inRegion(idx(igCenterX.toDset()), idx(igCenterY.toDset()), crSilver) and
      idx(igRmsTransverse.toDset())   >= minRms and
      idx(igRmsTransverse.toDset())   <= maxRms and
      idx(igLength.toDset())          <= maxLen and
      idx(igEccentricity.toDset())    <= maxEcc and
      idx(igHits.toDset())            >= minPix
    ) })
  else:
    result = df.filter(f{float -> bool: (
      inRegion(idx(igCenterX.toDset()), idx(igCenterY.toDset()), crSilver) and
      idx(igRmsTransverse.toDset())   >= minRms and
      idx(igRmsTransverse.toDset())   <= maxRms and
      idx(igLength.toDset())          <= maxLen and
      idx(igEccentricity.toDset())    <= maxEcc and
      idx(igHits.toDset())            >= minPix and
      idx(energyDset.toDset()) > eLow and idx(energyDset.toDset()) < eHigh
    ) })

proc cutXrayCleaning*(df: DataFrame, energy: float): DataFrame =
  result = df.cutXrayCleaning(energy.toRefTfKind())
