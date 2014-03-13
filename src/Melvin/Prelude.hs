{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Melvin uses both I/O functions and Text heavily. This module provides
-- everything a Melvin module should need.
module Melvin.Prelude (
  -- base's Prelude
  module X,
  st,
  stP,
  LogIO,

  -- retconned Prelude functions
  (++),
  show,
  (<$>),

  -- IO
  runMelvin,

  IO.hGetLine,
  IO.putStrLn,
  IO.hPutStr,

  -- Text
  Text,
  pack
) where

import           Control.Applicative
import           Control.Lens as X hiding        (Level)
import           Control.Monad.IO.Class
import           Control.Monad.Logger as X
import           Control.Monad.State as X hiding (join)
import           Data.Monoid as X
import           Data.Text                       (Text, pack)
import qualified Data.Text.IO as IO
import           FileLocation as X
import           Melvin.Internal.Orphans as X    ()
import           Melvin.Internal.MonadAsync as X
import           Pipes as X hiding               (each, (<~))
import           Pipes.Safe
import           Prelude as X hiding             ((++), putStrLn, print, show, lines
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ <= 704
                                                 , catch
#endif
                                                 )
import qualified Prelude as P
import           System.IO as X                  (Handle, hClose, hFlush, hIsClosed, hIsEOF)
import           Text.Printf.TH

type LogIO m = (MonadLogger m, MonadIO m)

-- | Simple utility functions.
show :: Show a => a -> Text
show = pack . P.show

(++) :: Monoid m => m -> m -> m
(++) = (<>)

-- | Dealing with the underlying Proxy monad upon which Melvin clients are
-- based.
runMelvin :: (LogIO m, MonadCatch m) => s -> Effect (SafeT (StateT s m)) r -> m (Either SomeException r)
runMelvin st_ m = catch
    (liftM Right $ evalStateT (runSafeT $ runEffect m) st_)
    (\e -> return (Left e))
