{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
module Pontarius.E2E.Types
where

import qualified Control.Monad.CryptoRandom as CR
import           Control.Monad.Error
import qualified Crypto.PubKey.DSA as DSA
import qualified Data.ByteString as BS
import           Data.Typeable (Typeable)
import           Control.Concurrent
import           Control.Concurrent.STM
import qualified Data.Map as Map
import           Network.Xmpp.Types as Xmpp
import qualified Crypto.Random as CRandom
import qualified Network.Xmpp as Xmpp

type CTR = BS.ByteString
type MAC = BS.ByteString
type DATA = BS.ByteString

type Pubkey = DSA.PublicKey

data DHKeyPair = DHKeyPair { pub  :: !Integer
                           , priv :: !Integer
                           } deriving Show

data MsgState = MsgStatePlaintext
              | MsgStateEncrypted
              | MsgStateFinished
              deriving (Eq, Show)

data SmpMessaging a = SendSmpMessage SmpMessage (SmpMessaging a)
                    | RecvSmpMessage Int (SmpMessage -> SmpMessaging a)
                    | SmpReturn a
                 deriving Functor

data ProtocolError = MACFailure
                   | ValueRange -- DH key outside [2, prime - 2]
                   | PubkeyMismatch -- Offered DSA pubkey doesn't match the one
                                    -- we have
                   | SignatureMismatch
                   | HashMismatch
                   | DeserializationError String -- couldn deserialize data
                                                 -- structure
                   | UnexpectedMessagetype
                   | WrongKeyID -- KeyID is not current or current + 1
                     deriving (Show, Eq)

data E2EError = WrongState String
              | RandomGenError CR.GenError
              | InstanceTagRange
              | NoPeerDHKey -- theirCurrentKey is Nothing
              | NoPubkey -- We don't know the pubkey with the give fingerprint
              | ProtocolError ProtocolError String -- One of the checks failed
                deriving (Show, Eq, Typeable)

instance Error E2EError where
    strMsg = WrongState

data AuthState = AuthStateNone
               | AuthStateAwaitingDHKey BS.ByteString
               | AuthStateAwaitingRevealsig DHCommitMessage
               | AuthStateAwaitingSig
                 deriving Show

data SmpMessage = SmpMessage1 {g2a, c2, d2, g3a, c3, d3 :: !Integer }
                | SmpMessage2 {g2b, c2', d2', g3b, c3'
                              , d3' , pb, qb, cp, d5, d6 :: !Integer}
                | SmpMessage3 {pa, qa, cp', d5, d6, ra, cr, d7 :: !Integer}
                | SmpMessage4 {rb, cr, d7' :: !Integer}
                | SmpMessage1Q { question :: BS.ByteString
                               , g2a, c2, d2, g3a, c3, d3 :: !Integer }

                  deriving (Show, Eq)

data E2EState = E2EState { authState        :: !AuthState
                         , msgState         :: !MsgState
                         , ourKeyID         :: !Integer -- KeyID of ourCurrentKey
                         , theirPublicKey   :: !(Maybe DSA.PublicKey) -- DSA
                         , ourCurrentKey    :: !DHKeyPair
                         , ourPreviousKey   :: !DHKeyPair
                         , mostRecentKey    :: !Integer -- KeyID of the most
                                                       -- recent key that the
                                                       -- other party
                                                       -- acknowledged receiving
                         , nextDH           :: !DHKeyPair
                         , theirKeyID       :: !Integer -- KeyID of the lastest
                                                       -- of their keys we have
                                                       -- on file
                         , theirCurrentKey  :: !(Maybe Integer)
                         , theirPreviousKey :: !(Maybe Integer)
                           -- Instance Tags
                         , counter          :: !Integer
                         , ssid             :: !(Maybe BS.ByteString)
                           -- SMP ------------------------------
                         , verified         :: !Bool
                         , smpState         :: !(Maybe (SmpMessaging (Either E2EError Bool)))
                         }

data MessagePayload = MP { messagePlaintext :: !BS.ByteString
--                         , tlvs :: ![TLV]
                         } deriving (Eq, Show)

-- data RawDataMessage = RDM { flags :: OtrByte
--                           , senderKeyID :: OtrInt
--                           , recipientKeyID :: OtrInt
--                           , nextDHy :: Integer
--                           , ctrHi :: CTR
--                           , messageAes128 :: DATA
--                           } deriving (Eq, Show)

-- data DataMessage = DM { rawDataMessage :: OtrRawDataMessage
--                       , messageMAC :: MAC
--                       , oldMACKeys  :: DATA
--                       } deriving (Eq, Show)

data KeyDerivatives = KD { kdSsid
                         , kdC
                         , kdC'
                         , kdM1
                         , kdM2
                         , kdM1'
                         , kdM2'
                           :: !BS.ByteString
                         }
                       deriving (Eq, Show)

data MessageKeys = MK { sendEncKey
                      , sendMacKey
                      , recvEncKey
                      , recvMacKey :: !BS.ByteString
                      } deriving Show

data DHCommitMessage = DHC{ gxBSEnc  :: !DATA
                          , gxBSHash :: !DATA
                          } deriving (Show, Eq)

data DHKeyMessage = DHK {gyMpi :: !Integer } deriving (Show, Eq)

data RevealSignatureMessage = RSM { revealedKey :: !DATA
                                  , rsmSig :: !SignatureMessage
                                  } deriving (Eq, Show)

data SignatureMessage = SM { encryptedSignature :: !DATA
                           , macdSignature :: !MAC
                           } deriving (Eq, Show)

data DataMessage = DM { senderKeyID :: !Integer
                      , recipientKeyID :: !Integer
                      , nextDHy :: !Integer
                      , ctrHi :: !CTR
                      , messageEnc :: !DATA
                      , messageMAC :: !DATA
                      }

                   deriving (Show, Eq)

data E2EAkeMessage = DHCommitMessage {unDHCommitMessage :: !DHCommitMessage}
                   | DHKeyMessage{unDHKeyMessage :: !DHKeyMessage}
                   | RevealSignatureMessage{ unRevealSignatureMessage::
                                                   !RevealSignatureMessage}
                   | SignatureMessage{unSignatureMessage :: !SignatureMessage}
                   deriving (Eq, Show)


data E2EParameters = E2EParameters { paramDHPrime :: !Integer
                                   , paramDHGenerator :: !Integer
                                   , paramDHKeySizeBits :: !Integer
                                   , paramEncrypt :: BS.ByteString -- IV
                                                  -> BS.ByteString -- key
                                                  -> BS.ByteString -- payload
                                                  -> BS.ByteString -- ciphertext
                                   , paramEncryptionBlockSize :: !Int
                                   , paramEncryptionKeySize :: !Int
                                   , paramHash :: BS.ByteString -> BS.ByteString
                                   , paramMac  :: BS.ByteString -- macKey
                                               -> BS.ByteString -- Payload
                                               -> BS.ByteString
                                   , paramCheckMac :: BS.ByteString -- macKey
                                                   -> BS.ByteString -- payload
                                                   -> BS.ByteString -- MAC
                                                   -> Bool
                                   , sendPubkey :: Bool
                                   }

type DSAKeyPair = (DSA.PublicKey, DSA.PrivateKey)

data E2EGlobals = E2EG { parameters :: !E2EParameters
                       , dsaKeyPair :: !DSAKeyPair
                       }

data KeyType = KeyTypeDSA | KeyTypeRSA -- ECDSA
                            deriving (Show, Read, Eq, Ord)

type Fingerprint = (KeyType, BS.ByteString)

data SignatureData = SD { sdPub   ::  !(Either DSA.PublicKey Fingerprint)
                        , sdKeyID :: !Integer
                        , sdSig   :: !DSA.Signature
                        } deriving (Eq, Show)

data AuthKeys = KeysRSM -- RevealSignatureMessage
              | KeysSM  -- SignatureMessage


data E2EMessage = E2EAkeMessage {unE2EAkeMessage ::  !E2EAkeMessage}
                | E2EDataMessage {unE2EDataMessage:: !DataMessage}
                | E2EEndSessionMessage
                  deriving Show

data Messaging a = SendMessage !E2EMessage (Messaging a)
                 | RecvMessage (E2EMessage -> Messaging a)
                 | GetPubkey Fingerprint (DSA.PublicKey -> Messaging a)
                 | Yield !BS.ByteString (Messaging a)
                 | AskSmpSecret !(Maybe BS.ByteString)
                                (BS.ByteString -> Messaging a)
                 | StateChange !MsgState (Messaging a)
                 | SmpAuthenticated !Bool (Messaging a)
                 | Log !String (Messaging a)
                 | Return a
                 deriving Functor

instance Show a => Show (Messaging a) where
    show (SendMessage msg f) = "SendMessage{" ++ show msg ++ "}> " ++ show f
    show (RecvMessage _) = "RecvMsg(...)"
    show (GetPubkey fp _) = "GetPubkey{" ++ show fp ++ "}(...)"
    show (Yield y f) = "Yield{" ++ show y ++ "}> " ++ show f
    show (AskSmpSecret q _) = "AskSmpSecret{" ++ show q ++ "}(..)"
    show (StateChange st f) = "StateChange{" ++ show st ++ "}> " ++ show f
    show (SmpAuthenticated b f) = "SmpAuthenticated{" ++ show b ++ "}> " ++ show f
    show (Log l f) = "Log{" ++ show l ++ "}> " ++ show f
    show (Return a) = "Return{" ++ show a ++ "}"


type DSAKeys = (DSA.PublicKey, DSA.PrivateKey)

type RunState g = Messaging ((Either E2EError (), E2EState), g)

data E2EContext = E2EContext { peers :: TMVar (Map.Map Xmpp.Jid
                                                 (E2ESession CRandom.SystemRNG))
                             , sessRef :: TVar (Maybe Xmpp.Session)
                             , globals :: E2EGlobals
                             , getCtxSecret :: Maybe BS.ByteString
                                            -> IO BS.ByteString
                             , getPKey :: Fingerprint -> IO (Maybe Pubkey)
                             }

data E2ESession g = E2ESession { e2eGlobals :: E2EGlobals
                               , e2eState :: MVar (Either (RunState g)
                                                  (E2EState, g))
                               , getSessSecret :: Maybe BS.ByteString
                                               -> IO BS.ByteString
                               , onSendMessage :: E2EMessage -> IO ()
                               , onStateChange :: MsgState -> IO ()
                               , onSmpAuthChange :: Bool -> IO ()
                               , getKey :: Fingerprint -> IO (Maybe Pubkey)
                               }
