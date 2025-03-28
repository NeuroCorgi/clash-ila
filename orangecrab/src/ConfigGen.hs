{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE NoFieldSelectors #-}

module ConfigGen where

import Clash.Prelude hiding (Exp)

import Data.Aeson

import Language.Haskell.TH

import Data.HList
import Data.Hashable

-- | A datakind enforcing a HList to be convertable to a list of tuples, with size and the label of each signal
class NamedSignal ts where
  getSizeAndName :: HList ts -> [(Int, String)]

instance NamedSignal '[] where
  getSizeAndName HNil = []

instance forall dom t ts. (BitPack t, NamedSignal ts) => NamedSignal ((Signal dom t, String) : ts) where
  getSizeAndName (HCons (_, label) xs) = (natToNum @(BitSize t), label) : getSizeAndName xs

writeConfig ::
  forall dom a n ts.
  ( KnownNat n
  , NamedSignal ts
  , Lift a
  ) =>
  -- | How many samples should it capture of each signal?
  SNat n ->
  -- | Merely an identifier, recommended to be the name of the toplevel design, but it can be any name you fancy
  String ->
  -- | A list of signals and labels (Strings) tupled together to sample
  HList ts ->
  -- | The same list of signals, but then bundled together
  Signal dom a ->
  -- | a `IlaConfig` in AST form, this should be passed directly to the ILA
  IO (Exp)
writeConfig size toplevelName namedSignals bundledSignals = do
  let sizeNames = getSizeAndName namedSignals

  let genSignals = (uncurry $ flip GenSignal) <$> sizeNames

  let nonHashed = GenIla toplevelName (natToNum @n) 0 genSignals
  let hashValue = hash nonHashed
  let hashValueBv = resize $ pack hashValue :: BitVector 32
  let hashedIla = GenIla toplevelName (natToNum @n) hashValue genSignals

  let genIlas = GenIlas [hashedIla]

  encodeFile "ilaconf.json" genIlas

  let ilaConf =
        IlaConfig
          { hash = hashValueBv
          , size = size
          , tracing = bundledSignals
          }

  [|ilaConf|]

ilaConfig ::
  forall dom a n ts.
  ( KnownNat n
  , NamedSignal ts
  , Lift a
  ) =>
  -- | How many samples should it capture of each signal?
  SNat n ->
  -- | Merely an identifier, recommended to be the name of the toplevel design, but it can be any name you fancy
  String ->
  -- | A list of signals and labels (Strings) tupled together to sample
  HList ts ->
  -- | The same list of signals, but then bundled together
  Signal dom a ->
  -- | The ILA configuration itself
  IlaConfig n (Signal dom a)
ilaConfig size toplevelName namedSignals bundledSignals =
  IlaConfig
    { hash = 0
    , size = size
    , tracing = bundledSignals
    }

-- A record containing the actual configuration of the ILA
data IlaConfig n a = IlaConfig
  { hash :: BitVector 32
  -- ^ A hash to verify which ILA the system is communicating with
  , size :: SNat n
  -- ^ Size of the buffers, aka; how many samples should it capture
  , tracing :: a
  -- ^ The signal to trace
  }
  deriving (Lift)

-- All types primarily just used to properly format a JSON document

-- | Individual signal JSON representation
data GenSignal = GenSignal
  { name :: String
  , width :: Int
  }
  deriving (Generic, Show, ToJSON, Eq, Hashable)

-- | Individual ILA JSON representation
data GenIla = GenIla
  { toplevel :: String
  , bufferSize :: Int
  , hash :: Int
  , signals :: [GenSignal]
  }
  deriving (Generic, Show, ToJSON, Eq, Hashable)

-- | Toplevel of the JSON file
data GenIlas = GenIlas
  { ilas :: [GenIla]
  }
  deriving (Generic, Show, ToJSON, Eq, Hashable)
