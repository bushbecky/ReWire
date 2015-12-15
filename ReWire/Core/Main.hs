module ReWire.Core.Main where

import System.IO
import System.Environment
import System.Console.GetOpt
import System.Exit
import ReWire.Core.Syntax
import ReWire.Core.FrontEnd
--import ReWire.Core.PrettyPrint
import ReWire.Core.PrettyPrintHaskell
import ReWire.Core.KindChecker
import ReWire.Core.TypeChecker
import ReWire.Core.Transformations.Interactive
import ReWire.PreHDL.CFG (mkDot,gather,linearize,cfgToProg)
import ReWire.PreHDL.GotoElim (gotoElim)
import ReWire.PreHDL.ElimEmpty (elimEmpty)
import ReWire.PreHDL.ToVHDL (toVHDL)
import ReWire.Core.Transformations.ToPreHDL (cfgFromRW,eu)
import Control.Monad (when)

data Flag = FlagCFG String
          | FlagLCFG String
          | FlagPre String
          | FlagGPre String
          | FlagO String
          | FlagI
          | FlagD
          deriving (Eq,Show)

options :: [OptDescr Flag]
options =
 [ Option ['d'] ["debug"] (NoArg FlagD)
                          "dump miscellaneous debugging information"
 , Option ['i'] []        (NoArg FlagI)
                          "run in interactive mode (overrides all other options)"
 , Option ['o'] []        (ReqArg FlagO "filename.vhd")
                          "generate VHDL"
 , Option []    ["cfg"]   (ReqArg FlagCFG "filename.dot")
                          "generate control flow graph before linearization"
 , Option []    ["lcfg"]  (ReqArg FlagLCFG "filename.dot")
                          "generate control flow graph after linearization"
 , Option []    ["pre"]   (ReqArg FlagPre "filename.phdl")
                          "generate PreHDL before goto elimination"
 , Option []    ["gpre"]  (ReqArg FlagGPre "filename.phdl")
                          "generate PreHDL after goto elimination"
 ]

exitUsage :: IO ()
exitUsage = hPutStr stderr (usageInfo "Usage: rwc [OPTION...] <filename.rw>" options) >> exitFailure

runFE :: Bool -> FilePath -> IO RWCProg
runFE fDebug filename = do
  res_p <- parseFile filename

  case res_p of
    ParseFailed loc m ->
       hPutStrLn stderr (prettyPrint loc ++ ":\n\t" ++ m) >> exitFailure
    ParseOk p         -> do

      when fDebug $ do
        putStrLn "parse finished"
        writeFile "show.out" (show p)
        putStrLn "show out finished"
        writeFile "Debug.hs" (show $ ppHaskellWithName p "Debug")
        putStrLn "debug out finished"        
      
      case kindcheck p of
        Just e  ->
          hPutStrLn stderr e >> exitFailure
        Nothing -> do
          when fDebug (putStrLn "kc finished")
          
          case typecheck p of
            Left e   -> hPutStrLn stderr e >> exitFailure
            Right p' -> do

              when fDebug $ do
                putStrLn "tc finished"
                writeFile "tc.out" (show p')
                putStrLn "tc debug print finished"

              return p'

main :: IO ()
main = do args                       <- getArgs

          let (flags,filenames,errs) =  getOpt Permute options args
          
          when (not (null errs)) (mapM_ (hPutStrLn stderr) errs >> exitUsage)
             
          when (length filenames /= 1) (hPutStrLn stderr "exactly one source file must be specified" >> exitUsage)

          let isActFlag (FlagCFG _)  = True
              isActFlag (FlagLCFG _) = True
              isActFlag (FlagPre _)  = True
              isActFlag (FlagGPre _) = True
              isActFlag (FlagO _)    = True
              isActFlag FlagI        = True
              isActFlag _            = False
          
          when (not (any isActFlag flags)) (hPutStrLn stderr "must specify at least one of -i, -o, --cfg, --lcfg, --pre, or --gpre" >> exitUsage)

          let filename               =  head filenames

          p <- runFE (FlagD `elem` flags) filename
          
          if FlagI `elem` flags then trans p
          else do
            let cfg     = cfgFromRW p
                cfgDot  = mkDot (gather (eu cfg))
                lcfgDot = mkDot (gather (linearize cfg))
                pre     = cfgToProg cfg
                gpre    = gotoElim pre
                vhdl    = toVHDL (elimEmpty gpre)
                doDump (FlagCFG f)  = writeFile f $ mkDot $ gather $ eu cfg
                doDump (FlagLCFG f) = writeFile f $ mkDot $ gather $ linearize cfg
                doDump (FlagPre f)  = writeFile f $ show pre
                doDump (FlagGPre f) = writeFile f $ show gpre
                doDump (FlagO f)    = writeFile f vhdl
                doDump _            = return ()
            mapM_ doDump flags
