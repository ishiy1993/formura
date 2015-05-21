import Control.Monad
import Data.List
import qualified Data.Map as M
import System.Environment
import System.Process
import Text.Printf

data Key = Key { algorithm :: String, problemSize :: Int }
           deriving (Eq, Ord, Show, Read)

main :: IO ()
main = do
  getArgs >>= mapM_ process

process :: FilePath -> IO ()
process fn = do
  contentStr <- readFile fn
  let allBench :: M.Map Key [Double]
      allBench = foldr (M.unionWith (++)) M.empty $ map p1 $ lines contentStr

      p1 :: String -> M.Map Key [Double]
      p1 str = M.singleton (Key (ws!!0) (read $ ws!!2)) [read $ ws!!7]
        where ws = words str
  mapM_ putStrLn $ map ppr $ M.toList allBench

ppr :: (Key, [Double]) -> String
ppr (k, xs)= printf "%s %d %f %f %f" (algorithm k) (problemSize k) mid lo hi
  where
    xsSorted = sort xs
    n = length xs
    mid = (xsSorted !! (n `div` 2))
    lo  = (xsSorted !! ((n) `div` 4))
    hi  = (xsSorted !! ((3*n) `div` 4))