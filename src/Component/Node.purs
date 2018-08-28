module Component.Node where

import Crypto.Simple
import Prelude

import CSS (Color, color, rgb, hsl)
import Color.Scheme.Clrs (red)
import Data.Array (all, head, length, (!!), (:))
import Data.Enum (fromEnum)
import Data.Foldable (foldl, sum)
import Data.Int (toNumber)
import Data.Maybe (Maybe(..), maybe, fromMaybe)
import Data.Monoid ((<>))
import Data.String (take, toCodePointArray)
import Effect.Aff (Aff, Milliseconds(..), delay, forkAff)
import Effect.Class.Console (log)
import Effect.Random (randomInt)
import Halogen (ClassName(..))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.CSS as CSS
import Data.Blockchain
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

data Message = NewBlockchain Blockchain

type State = {
  keypair :: KeyPair,
  candidateBlock :: Block,
  blockchain :: Blockchain,
  seed :: Int,
  id :: Int,
  peers :: Array NodeId,
  isMining :: Boolean,
  receivedBlock :: Boolean,
  showMenu :: Boolean,
  isGreedy :: Boolean,
  minedBlock :: Boolean
}


getAddress :: State -> String
getAddress { keypair: { public } } = toString public

addBlock :: State -> State
addBlock st =
  let
    st' = st { blockchain = st.candidateBlock : st.blockchain }
    newCandidate = mkCandidateBlock st.id (getAddress st') st'.seed st'.blockchain
  in
    st' { candidateBlock = newCandidate }

type NodeId = Int


type Input = { id :: Int, peers :: Array NodeId, seed :: Int, keypair :: KeyPair }

data Query a
  = MineBlock a
  | GetPeers (Array NodeId -> a)
  | GetHash (String -> a)
  | ReceiveBlockchain Blockchain a
  | ShowMenu Boolean a
  | MakeGreedy Boolean a

ui :: H.Component HH.HTML Query Input Message Aff
ui =
  H.component
    { initialState
    , render
    , eval
    , receiver: const Nothing
    }
  where

  initialState { id, seed, peers, keypair} = {
    keypair,
    id,
    candidateBlock: Block {
      nonce: seed,
      prevHash: "",
      hash: "",
      transactions: Transactions {
        coinbase: Coinbase { to: show id },
        transactions: []
      }
    },
    blockchain: [],
    seed,
    peers,
    isMining: false,
    receivedBlock: false,
    minedBlock: false,
    isGreedy: false,
    showMenu: false
  }

  colorFromHash :: String -> Color
  colorFromHash string =
    let
      h = toNumber $ flip mod 360 $ sum $ (fromEnum) <$> toCodePointArray string
    in
      hsl h 1.0 0.5

  render :: State -> H.ComponentHTML Query
  render st =
    let
      chainLength = length st.blockchain
    in
    HH.div [ class_ $ "node-container " <> if st.showMenu then "floating" else ""] [
      HH.div [ class_ $ "node "
        <> if st.receivedBlock then "received-block " else " "
        <> if st.minedBlock then "mined-block " else " "
        <> if st.isMining then "mining " else " ",
        HE.onClick $ HE.input_ $ ShowMenu true
        ] [
      ],
      (if chainLength > 0 then
        HH.div [
          class_ "block-height",
          CSS.style do color (colorFromHash prevHash)
        ] [
          HH.strong_ [HH.text $ show $ chainLength]
        ]
        else HH.text ""
      ),
      if st.showMenu
        then
          HH.div_ [
            HH.div [
              class_ "menu floating"
            ] [
              HH.div [
                class_ "menu-item",
                HE.onClick $ HE.input_ MineBlock
              ] [
                HH.text "Start Mining"
              ],
              HH.div [
                class_ "menu-item",
                HE.onClick $ HE.input_ $ MakeGreedy true
              ] [
                HH.text "Make Greedy"
              ]
            ],
            HH.div [
              class_ "overlay",
              HE.onClick $ HE.input_ $ ShowMenu false
            ] [
            ]
          ]
        else
          HH.text ""
    ]
    where
      prevHash = (\(Block {prevHash}) -> prevHash) st.candidateBlock

  class_ = HP.class_ <<< ClassName

  eval :: Query ~> H.ComponentDSL State Query Message Aff
  eval = case _ of
    GetPeers reply -> do
      peers <- H.gets _.peers
      pure (reply peers)

    GetHash reply -> do
      blockchain <- H.gets _.blockchain
      case head blockchain of
        Just (Block {hash}) ->
          pure (reply hash)
        Nothing ->
          pure (reply "")

    ReceiveBlockchain newBlockchain next -> do
      isGreedy <- H.gets _.isGreedy
      if isGreedy then pure next
        else do
          blockchain <- H.gets _.blockchain
          if length newBlockchain > length blockchain && isValidBlockchain newBlockchain
            then do
              _ <- receivedBlock
              st <- H.get
              H.modify_ ( _ {
                blockchain = newBlockchain,
                candidateBlock = mkCandidateBlock st.id (getAddress st) st.seed newBlockchain
                })
              _ <- H.fork $ do
                H.liftAff $ delay $ Milliseconds 500.0
                H.raise $ NewBlockchain newBlockchain
              pure next
            else
              pure next

    ShowMenu showMenu next -> do
      H.modify_ _ { showMenu = showMenu }
      pure next

    MakeGreedy isGreedy next -> do
      H.modify_ _ { isGreedy = isGreedy }
      pure next

    MineBlock next -> do
      H.modify_ _ { isMining = true }
      block <- H.gets (mineOnce <<<_.candidateBlock)
      H.modify_ _ { candidateBlock = block}

      if isValidBlock block
        then do
          minedBlock block
          pure next
        else do
          _ <- H.fork $ do
            H.liftAff $ delay $ Milliseconds 20.0
            eval $ MineBlock next
          pure next

receivedBlock = do
  H.modify_ _ { receivedBlock = true }
  H.fork $ do
    H.liftAff $ delay $ Milliseconds 300.0
    H.modify_ _ { receivedBlock = false }

minedBlock block = do
  H.modify_ addBlock
  blockchain <- H.gets _.blockchain
  H.modify_ _ { isMining = false, minedBlock = true }
  _ <- H.fork $ do
    H.liftAff $ delay $ Milliseconds 1000.0
    H.modify_ _ { minedBlock = false }
  H.raise $ NewBlockchain blockchain
