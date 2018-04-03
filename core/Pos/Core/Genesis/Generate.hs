-- | Generation of genesis data for testnet.

module Pos.Core.Genesis.Generate
       ( GeneratedGenesisData (..)
       , GeneratedSecrets (..)
       , PoorSecret (..)
       , RichSecrets (..)

       , generateGenesisData

       -- * Helpers which are also used by keygen.
       , generateRichSecrets
       , generateFakeAvvm
       , poorSecretToEncKey
       , poorSecretToKey
       ) where

import           Universum

import           Control.Lens (coerced)
import           Crypto.Random (MonadRandom, getRandomBytes)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as Map
import           Serokell.Util.Verify (VerificationRes (..), formatAllErrors, verifyGeneric)

import           Pos.Binary.Class (asBinary, serialize')
import           Pos.Binary.Core.Address ()
import           Pos.Binary.Core.Delegation ()
import           Pos.Binary.Core.Slotting ()
import           Pos.Core.Common (Address, Coin, IsBootstrapEraAddr (..), StakeholderId,
                                  addressHash, applyCoinPortionDown, coinToInteger,
                                  deriveFirstHDAddress, makePubKeyAddressBoot, mkCoin, sumCoins,
                                  unsafeIntegerToCoin)
import           Pos.Core.Configuration.BlockVersionData (HasGenesisBlockVersionData)
import           Pos.Core.Configuration.Protocol (HasProtocolConstants, vssMaxTTL, vssMinTTL)
import           Pos.Core.Delegation (HeavyDlgIndex (..), ProxySKHeavy)
import           Pos.Core.Genesis.Helpers (mkGenesisDelegation)
import           Pos.Core.Genesis.Types (FakeAvvmOptions (..), GenesisAvvmBalances (..),
                                         GenesisDelegation, GenesisInitializer (..),
                                         GenesisNonAvvmBalances (..),
                                         GenesisVssCertificatesMap (..), GenesisWStakeholders (..),
                                         TestnetBalanceOptions (..))
import           Pos.Core.Ssc.Vss (VssCertificate, mkVssCertificate, mkVssCertificatesMap)
import           Pos.Crypto (EncryptedSecretKey, HasCryptoConfiguration, RedeemPublicKey, SecretKey,
                             VssKeyPair, createPsk, deterministic, emptyPassphrase, encToSecret,
                             keyGen, noPassEncrypt, randomNumberInRange, redeemDeterministicKeyGen,
                             safeKeyGen, toPublic, toVssPublicKey, vssKeyGen)
import           Pos.Util.Util (leftToPanic)

-- | Data generated by @generateGenesisData@ using genesis-spec.
data GeneratedGenesisData = GeneratedGenesisData
    { ggdNonAvvm          :: !GenesisNonAvvmBalances
    -- ^ Non-avvm balances
    , ggdAvvm             :: !GenesisAvvmBalances
    -- ^ Avvm balances (fake and real).
    , ggdBootStakeholders :: !GenesisWStakeholders
    -- ^ Set of boot stakeholders (richmen addresses or custom addresses)
    , ggdVssCerts         :: !GenesisVssCertificatesMap
    -- ^ Genesis vss data (vss certs of richmen)
    , ggdDelegation       :: !GenesisDelegation
    -- ^ Genesis heavyweight delegation certificates (empty if
    -- 'tiUseHeavyDlg' is 'False').
    , ggdSecrets          :: !GeneratedSecrets
    -- ^ Secrets which can unlock genesis data (if known).
    }

-- | All valuable secrets of rich node.
data RichSecrets = RichSecrets
    { rsPrimaryKey :: !SecretKey
    -- ^ Primary secret key. 'StakeholderId' associated with it
    -- generally contains huge stake. Also associated PubKey address
    -- with bootstrap era contains huge balance.
    , rsVssKeyPair :: !VssKeyPair
    -- ^ VSS key pair used for SSC.
    }

-- | Poor node secret
data PoorSecret = PoorSecret SecretKey | PoorEncryptedSecret EncryptedSecretKey

-- | Valuable secrets which can unlock genesis data.
data GeneratedSecrets = GeneratedSecrets
    { gsDlgIssuersSecrets :: ![SecretKey]
    -- ^ Secret keys which issued heavyweight delegation certificates
    -- in genesis data. If genesis heavyweight delegation isn't used,
    -- this list is empty.
    , gsRichSecrets       :: ![RichSecrets]
    -- ^ All secrets of rich nodes.
    , gsPoorSecrets       :: ![PoorSecret]
    -- ^ Keys for HD addresses of poor nodes.
    , gsFakeAvvmSeeds     :: ![ByteString]
    -- ^ Fake avvm seeds.
    }

generateGenesisData
    :: (HasCryptoConfiguration, HasGenesisBlockVersionData, HasProtocolConstants)
    => GenesisInitializer
    -> GenesisAvvmBalances
    -> GeneratedGenesisData
generateGenesisData (GenesisInitializer{..}) realAvvmBalances = deterministic (serialize' giSeed) $ do
    let TestnetBalanceOptions{..} = giTestBalance

    -- apply ggdAvvmBalanceFactor
    let applyAvvmBalanceFactor :: HashMap k Coin -> HashMap k Coin
        applyAvvmBalanceFactor = map (applyCoinPortionDown giAvvmBalanceFactor)
        realAvvmMultiplied :: GenesisAvvmBalances
        realAvvmMultiplied = realAvvmBalances & coerced %~ applyAvvmBalanceFactor

    -- Compute total balance to generate
    let
        avvmSum = sumCoins realAvvmMultiplied
        maxTnBalance =
            case coinToInteger (maxBound @Coin) - avvmSum of
                v | v < 0 -> error "avvmSum exceeds maximal value"
                  | otherwise -> fromIntegral $! v
        tnBalance = min maxTnBalance tboTotalBalance

    -- Generate AVVM stuff
    (fakeAvvmDistr, fakeAvvmSeeds, fakeAvvmBalance) <- generateFakeAvvmGenesis giFakeAvvmBalance

    -- Generate all secrets
    let replicateRich :: forall a m . Applicative m => m a -> m [a]
        replicateRich = replicateM (fromIntegral tboRichmen)
        replicatePoor :: forall a m . Applicative m => m a -> m [a]
        replicatePoor = replicateM (fromIntegral tboPoors)
        genPoorSecret | tboUseHDAddresses = PoorEncryptedSecret . snd <$> safeKeyGen emptyPassphrase
                      | otherwise = PoorSecret . snd <$> keyGen
    dlgIssuersSecrets <-
        case giUseHeavyDlg of
            False -> pure []
            True  -> replicateRich (snd <$> keyGen)
    richmenSecrets <- replicateRich generateRichSecrets
    poorsSecrets <- replicatePoor genPoorSecret

    -- Heavyweight delegation.
    -- genesisDlgList is empty if giUseHeavyDlg = False
    let genesisDlgList :: [ProxySKHeavy]
        genesisDlgList =
            (\(issuerSk, RichSecrets {..}) ->
                 createPsk issuerSk (toPublic rsPrimaryKey) (HeavyDlgIndex 0)) <$>
            zip dlgIssuersSecrets richmenSecrets
        genesisDlg =
            leftToPanic "generateGenesisData: genesisDlg" $
            mkGenesisDelegation genesisDlgList

    -- Bootstrap stakeholders
    let bootSecrets
            | giUseHeavyDlg = dlgIssuersSecrets
            | otherwise = map rsPrimaryKey richmenSecrets
        bootStakeholders :: Map StakeholderId Word16
        bootStakeholders =
            Map.fromList $
            map ((,1) . addressHash . toPublic) bootSecrets

    -- VSS certificates
    vssCertsList <- mapM generateVssCert richmenSecrets
    let toVss = mkVssCertificatesMap
        vssCerts = GenesisVssCertificatesMap $ toVss vssCertsList

    -- Non AVVM balances
    ---- Addresses
    let createAddressRich :: SecretKey -> Address
        createAddressRich (toPublic -> pk) = makePubKeyAddressBoot pk
    let createAddressPoor :: PoorSecret -> Address
        createAddressPoor (PoorEncryptedSecret hdwSk) =
            fst $
            fromMaybe (error "generateGenesisData: pass mismatch") $
            deriveFirstHDAddress
                (IsBootstrapEraAddr True)
                emptyPassphrase
                hdwSk
        createAddressPoor (PoorSecret secret) = makePubKeyAddressBoot (toPublic secret)
    let richAddresses = map (createAddressRich . rsPrimaryKey) richmenSecrets
        poorAddresses = map createAddressPoor poorsSecrets

    ---- Balances
    let safeZip s a b =
            if length a /= length b
            then error $ s <> " :lists differ in size, " <> show (length a) <>
                         " and " <> show (length b)
            else zip a b

        (richBals, poorBals) =
            genTestnetDistribution giTestBalance (fromIntegral $ tnBalance - fakeAvvmBalance)
        -- ^ Rich and poor balances
        nonAvvmDistr = HM.fromList $
            safeZip "rich" richAddresses richBals ++
            safeZip "poor" poorAddresses poorBals

    pure GeneratedGenesisData
        { ggdNonAvvm = GenesisNonAvvmBalances nonAvvmDistr
        , ggdAvvm = fakeAvvmDistr <> realAvvmMultiplied
        , ggdBootStakeholders = GenesisWStakeholders bootStakeholders
        , ggdVssCerts = vssCerts
        , ggdDelegation = genesisDlg
        , ggdSecrets = GeneratedSecrets
              { gsDlgIssuersSecrets = dlgIssuersSecrets
              , gsRichSecrets = richmenSecrets
              , gsPoorSecrets = poorsSecrets
              , gsFakeAvvmSeeds = fakeAvvmSeeds
              }
        }

----------------------------------------------------------------------------
-- Exported helpers
----------------------------------------------------------------------------

generateFakeAvvm :: MonadRandom m => m (RedeemPublicKey, ByteString)
generateFakeAvvm = do
    seed <- getRandomBytes 32
    let (pk, _) = fromMaybe
            (error "Impossible - seed is not 32 bytes long") $
            redeemDeterministicKeyGen seed
    pure (pk, seed)

generateRichSecrets :: (MonadRandom m) => m RichSecrets
generateRichSecrets = do
    rsPrimaryKey <- snd <$> keyGen
    rsVssKeyPair <- vssKeyGen
    return RichSecrets {..}

poorSecretToKey :: PoorSecret -> SecretKey
poorSecretToKey (PoorSecret key)             = key
poorSecretToKey (PoorEncryptedSecret encKey) = encToSecret encKey

poorSecretToEncKey :: PoorSecret -> EncryptedSecretKey
poorSecretToEncKey (PoorSecret key)           = noPassEncrypt key
poorSecretToEncKey (PoorEncryptedSecret encr) = encr

----------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------

generateFakeAvvmGenesis
    :: (MonadRandom m)
    => FakeAvvmOptions -> m (GenesisAvvmBalances, [ByteString], Word64)
generateFakeAvvmGenesis FakeAvvmOptions{..} = do
    fakeAvvmPubkeysAndSeeds <- replicateM (fromIntegral faoCount) generateFakeAvvm
    let oneBalance = mkCoin $ fromIntegral faoOneBalance
        fakeAvvms = map ((,oneBalance) . fst) fakeAvvmPubkeysAndSeeds
    pure ( GenesisAvvmBalances $ HM.fromList fakeAvvms
         , map snd fakeAvvmPubkeysAndSeeds
         , faoOneBalance * fromIntegral faoCount)

generateVssCert ::
       (HasCryptoConfiguration, HasProtocolConstants, MonadRandom m)
    => RichSecrets
    -> m VssCertificate
generateVssCert RichSecrets {..} = do
    expiry <- fromInteger <$>
        randomNumberInRange (vssMinTTL - 1) (vssMaxTTL - 1)
    let vssPk = asBinary $ toVssPublicKey rsVssKeyPair
        vssCert = mkVssCertificate rsPrimaryKey vssPk expiry
    return vssCert

-- Generates balance distribution for testnet.
genTestnetDistribution ::
       HasGenesisBlockVersionData
    => TestnetBalanceOptions
    -> Integer
    -> ([Coin], [Coin])
genTestnetDistribution TestnetBalanceOptions {..} testBalance =
    checkConsistency (richBalances, poorBalances)
  where
    richs = fromIntegral tboRichmen
    poors = fromIntegral tboPoors
    -- Calculate actual balances
    desiredRichBalance = getShare tboRichmenShare testBalance
    oneRichmanBalance
        | richs == 0 = 0
        | otherwise =
            desiredRichBalance `div` richs +
            if desiredRichBalance `mod` richs > 0
                then 1
                else 0
    realRichBalance = oneRichmanBalance * richs
    poorsBalance = testBalance - realRichBalance
    onePoorBalance | poors == 0 = 0
                   | otherwise = poorsBalance `div` poors
    realPoorBalance = onePoorBalance * poors
    richBalances =
        replicate (fromInteger richs) (unsafeIntegerToCoin oneRichmanBalance)
    poorBalances =
        replicate (fromInteger poors) (unsafeIntegerToCoin onePoorBalance)

    -- Consistency checks
    everythingIsConsistent :: [(Bool, Text)]
    everythingIsConsistent =
        [ ( realRichBalance + realPoorBalance <= testBalance
          , "Real rich + poor balance is more than desired.")
        ]

    checkConsistency :: a -> a
    checkConsistency =
        case verifyGeneric everythingIsConsistent of
            VerSuccess        -> identity
            VerFailure errors -> error $ formatAllErrors errors

    getShare :: Double -> Integer -> Integer
    getShare sh n = round $ sh * fromInteger n
