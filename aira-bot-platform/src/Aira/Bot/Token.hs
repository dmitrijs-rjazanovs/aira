{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module      :  Aira.Bot.Token
-- Copyright   :  Alexander Krupenkin 2016
-- License     :  BSD3
--
-- Maintainer  :  mail@akru.me
-- Stability   :  experimental
-- Portability :  portable
--
-- Aira Ethereum token manipulation bot stories.
--
module Aira.Bot.Token (
    transfer
  , balance
  , refill
  , send
  , ethBalance
  ) where

import Network.Ethereum.Web3.Types (CallMode(Latest))
import Control.Monad.IO.Class (liftIO)
import Data.Text.Read (hexadecimal)
import Control.Exception (throwIO)
import Network.Ethereum.Web3.Api
import Network.Ethereum.Web3
import Control.Monad (when)
import Web.Bot.Persist
import Web.Bot.User
import Web.Bot

import qualified Aira.Contract.TokenSelling as TokenSelling
import qualified Aira.Contract.Token        as ERC20
import qualified Data.Text                  as T
import Aira.Bot.Common
import Aira.Bot.Proxy
import Aira.TextFormat
import Aira.Registrar
import Aira.Account

ethBalance :: (Provider a, Unit u) => Address -> Web3 a u
ethBalance address = do
    res <- eth_getBalance address Latest
    case hexadecimal res of
        Right (x, _) -> return (fromWei x)
        Left e       -> liftIO $ throwIO (ParserFail e)

transfer :: Persist a => AiraStory a
transfer = selectToken transferAIRA transferERC20

balance :: AiraStory a
balance = selectToken balanceAIRA balanceERC20

selectToken :: AiraStory a -> AiraStory a -> AiraStory a
selectToken f1 f2 a = do
    tokenType <- select "Token to use:" [["Ether"], ["ERC20"]]
    case tokenType :: Text of
        "Ether" -> f1 a
        "ERC20" -> f2 a
        x -> return $ toMessage ("Unknown option `" <> x <> "`!")

requestProxy :: Persist a => StoryT (Bot a) Address
requestProxy = do
    ident <- question "Recipient user identity:"
    mbUser <- lift $ runDB $ getBy (UserIdentity ident)
    case fmap entityVal mbUser of
        Just user -> do
            yield $ toMessage $ "Identity found, recipient is " <> userName user
            head <$> lift (userProxies user)
        Nothing -> do
            yield $ toMessage ("Unknown identity, please check and try again." :: Text)
            requestProxy

transferERC20 :: Persist a => AiraStory a
transferERC20 (_, px : _) = do
    token <- question "Token address:"
    dest  <- requestProxy
    amount <- question "Value in tokens:"
    res <- airaWeb3 $ do
        value <- ERC20.toDecimals token amount
        bal   <- ERC20.balanceOf token px

        if value > bal
        then liftIO $ throwIO $ UserFail $
                "Balance is too low: " ++ show bal
                                       ++ " requested: " ++ show value
        else proxy px token nopay (ERC20.TransferData dest value)

    return $ toMessage $ case res of
        Right tx -> "Success " <> uri_tx tx
        Left e   -> "Error " <> T.pack (show e)

transferERC20 _ = return $ toMessage $ T.unlines
    [ "Your account isn't work correctly!"
    , "Please wait on initiation step or call Airalab support." ]

transferAIRA :: Persist a => AiraStory a
transferAIRA (_, px : _) = do
    dest   <- requestProxy
    amount <- question "Value in ethers:"
    res <- airaWeb3 $ do
        bal <- ethBalance px

        if amount > bal
        then liftIO $ throwIO $ UserFail $
                "Balance is too low: " ++ show bal
                                       ++ " requested: " ++ show amount
        else proxy px dest (amount :: Ether) NoMethod

    return $ toMessage $ case res of
        Right tx -> "Success " <> uri_tx tx
        Left e   -> T.pack (show e)

transferAIRA _ = return $ toMessage $ T.unlines
    [ "Your account isn't work correctly!"
    , "Please wait on initiation step or call Airalab support." ]

balanceAIRA :: AiraStory a
balanceAIRA (_, pxs) = do
    res <- airaWeb3 $ mapM ethBalance pxs
    return $ toMessage $ case res of
        Left e -> T.pack (show e)
        Right balances -> T.unlines $
            "Account balances:" : fmap pxBalance (zip pxs balances)
  where pxBalance :: (Address, Ether) -> Text
        pxBalance (p, b) = "- " <> uri_address p <> ": " <> T.pack (show b)

balanceERC20 :: AiraStory a
balanceERC20 (_, pxs) = do
    token <- question "Token address:"
    res <- airaWeb3 $ do
        bs <- mapM (ERC20.balanceOf token) pxs
        mapM (ERC20.fromDecimals token) bs
    return $ toMessage $ case res of
        Left e -> T.pack (show e)
        Right balances -> T.unlines $
            "Account balances: " : fmap pxBalance (zip pxs balances)
  where pxBalance :: (Address, Double) -> Text
        pxBalance (p, b) = "- " <> uri_address p <> ": " <> T.pack (show b)

send :: AiraStory a
send (_, px : _) = do
    dest   <- question "Recipient Ethereum address:"
    amount <- question "Amount of `ether` you want to send:"
    res <- airaWeb3 $ proxy px dest (amount :: Ether) NoMethod
    return $ toMessage $ case res of
        Right tx -> "Success " <> uri_tx tx
        Left e   -> T.pack (show e)

send _ = return $ toMessage $ T.unlines
    [ "Your account isn't work correctly!"
    , "Please wait on initiation step or call Airalab support." ]

refill :: AiraStory a
refill (_, px : _) = do
    amount <- question "Amount of `Air` to buy:"
    res <- airaWeb3 $ do
        airSale <- getAddress "TokenAirSelling.contract"
        price <- TokenSelling.price_wei airSale
        return (fromWei (amount * price) :: Ether)
    case res of
        Left e -> return $ toMessage $ T.pack (show e)
        Right amount_ether -> do
            res <- select ("Do you want to pay "
                            <> T.pack (show amount_ether)
                            <> " for " <> T.pack (show amount) <> " Air?")
                            [["Yes"], ["No"]]
            case res :: Text of
                "Yes" -> do
                    res <- airaWeb3 $ do
                        avail <- ethBalance px
                        airSale <- getAddress "TokenAirSelling.contract"
                        when (avail < amount_ether) $
                            liftIO $ throwIO $ UserFail $
                                "To low account balance: "
                                    ++ show avail
                                    ++ " requested: "
                                    ++ show amount_ether
                        -- Buy tokens
                        tx <- proxy px airSale amount_ether TokenSelling.BuyData

                        air <- getAddress "TokenAir.contract"
                        bot <- getAddress "AiraEth.bot"
                        -- Approve tokens
                        proxy' px air nopay $ ERC20.ApproveData bot amount

                        return tx
                    return $ toMessage $ case res of
                        Left e -> T.pack (show e)
                        Right _ -> "Buy transaction sended."

                _ -> return $ toMessage ("Request canceled." :: Text)

refill _ = return $ toMessage $ T.unlines
    [ "Your account isn't work correctly!"
    , "Please wait on initiation step or call Airalab support." ]
