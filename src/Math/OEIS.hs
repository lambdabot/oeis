-- | Interface to the Online Encyclopedia of Integer Sequences (OEIS). See
-- <http://oeis.org/>.

module Math.OEIS
  ( -- * Example usage
    -- $sample

    -- * Lookup functions
    getSequenceByID,    lookupSequenceByID,
    extendSequence,     lookupSequence,
    getSequenceByID_IO, lookupSequenceByID_IO,
    extendSequence_IO,  lookupSequence_IO,
    searchSequence_IO,  lookupOEIS,

    -- * Data structures
    SequenceData,
    Language(..), Keyword(..),
    OEISSequence(..)
  ) where

import Control.Arrow    (second, (***))
import Data.Char        (isDigit, isSpace, toUpper, toLower)
import Data.List        (intercalate, isPrefixOf, tails, foldl')
import Data.Maybe       (listToMaybe, fromMaybe)
import Network.HTTP     (simpleHTTP, rspBody, rspCode, rqBody, rqHeaders, rqMethod, rqURI, Request(..), RequestMethod(GET))
import Network.URI      (escapeURIString, isAllowedInURI, parseURI, URI)
import System.IO.Unsafe (unsafePerformIO)

type SequenceData = [Integer]

-- | Interpret a string as a OEIS request, and return the results as Strings.
lookupOEIS :: String -> IO [String]
lookupOEIS a = do
         let a'  = commas . reverse . dropWhile isSpace . reverse . dropWhile isSpace $ a
         x <- searchSequence_IO a'
         case x of
            Nothing -> return ["Sequence not found."]
            Just s  -> return [description s, show $ sequenceData s]
 where commas []                     = []
       commas (x:' ':xs) | isDigit x = x : ',' : commas xs
       commas (x:xs)                 = x : commas xs

-- | Look up a sequence in the OEIS using its search function.
searchSequence_IO :: String -> IO (Maybe OEISSequence)
searchSequence_IO x = getOEIS (baseSearchURI ++) (escapeURIString isAllowedInURI x)

-- | Look up a sequence in the OEIS by its catalog number. Generally this would
-- be its A-number, but M-numbers (from the /Encyclopedia of Integer
-- Sequences/) and N-numbers (from the /Handbook of Integer Sequences/) can be
-- used as well.
--
-- Note that the result is not in the 'IO' monad, even though the
-- implementation requires looking up information via the Internet. There are
-- no side effects to speak of, and from a practical point of view the function
-- is referentially transparent (OEIS A-numbers could change in theory, but
-- it's extremely unlikely).
--
-- Examples:
--
-- > Prelude Math.OEIS> getSequenceByID "A000040"    -- the prime numbers
-- > Just [2,3,5,7,11,13,17,19,23,29,31,37,41,43,47...
-- >
-- > Prelude Math.OEIS> getSequenceByID "nosuch"     -- no such sequence!
-- > Nothing

getSequenceByID :: String -> Maybe SequenceData
getSequenceByID = unsafePerformIO . getSequenceByID_IO

-- | The same as 'getSequenceByID', but with a result in the 'IO' monad.
getSequenceByID_IO :: String -> IO (Maybe SequenceData)
getSequenceByID_IO x = fmap (fmap sequenceData) (lookupSequenceByID_IO x)

-- | Look up a sequence by ID number, returning a data structure containing the
-- entirety of the information the OEIS has on the sequence.
--
-- The standard disclaimer about not being in the 'IO' monad applies.
--
-- Examples:
--
-- > Prelude Math.OEIS> description `fmap` lookupSequenceByID "A000040"
-- > Just "The prime numbers."
-- >
-- > Prelude Math.OEIS> keywords `fmap` lookupSequenceByID "A000105"
-- > Just [Nonn,Hard,Nice,Core]

lookupSequenceByID :: String -> Maybe OEISSequence
lookupSequenceByID = unsafePerformIO . lookupSequenceByID_IO

-- | The same as 'lookupSequenceByID', but in the 'IO' monad.
lookupSequenceByID_IO :: String -> IO (Maybe OEISSequence)
lookupSequenceByID_IO = getOEIS idSearchURI

-- | Extend a sequence by using it as a lookup to the OEIS, taking the first
-- sequence returned as a result, and using it to augment the original
-- sequence.
--
-- Note that @xs@ is guaranteed to be a prefix of @extendSequence xs@. If the
-- matched OEIS sequence contains any elements prior to those matching @xs@,
-- they will be dropped. In addition, if no matching sequences are found, @xs@
-- will be returned unchanged.
--
-- The result is not in the 'IO' monad even though the implementation requires
-- looking up information via the Internet. There are no side effects, and
-- practically speaking this function is referentially transparent
-- (technically, results may change from time to time when the OEIS database is
-- updated; this is slightly more likely than the results of 'getSequenceByID'
-- changing, but still unlikely enough to be essentially a non-issue. Again,
-- purists may use 'extendSequence_IO').
--
-- Examples:
--
-- > Prelude Math.OEIS> extendSequence [5,7,11,13,17]
-- > [5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71...
--
-- > Prelude Math.OEIS> extendSequence [2,4,8,16,32]
-- > [2,4,8,16,32,64,128,256,512,1024,2048,4096,8192...
--
-- > Prelude Math.OEIS> extendSequence [9,8,7,41,562]   -- nothing matches
-- > [9,8,7,41,562]

extendSequence :: SequenceData -> SequenceData
extendSequence = unsafePerformIO . extendSequence_IO

-- | The same as 'extendSequence', but in the 'IO' monad.
extendSequence_IO :: [Integer] -> IO [Integer]
extendSequence_IO [] = return []
extendSequence_IO xs = do oeis <- lookupSequence_IO xs
                          case oeis of
                            Nothing -> return xs
                            Just s  -> return $ extend xs (sequenceData s)

-- | Find a matching sequence in the OEIS database, returning a data structure
-- containing the entirety of the information the OEIS has on the sequence.
--
-- The standard disclaimer about not being in the 'IO' monad applies.
lookupSequence :: SequenceData -> Maybe OEISSequence
lookupSequence = unsafePerformIO . lookupSequence_IO

-- | The same as 'lookupSequence', but in the 'IO' monad.
lookupSequence_IO :: SequenceData -> IO (Maybe OEISSequence)
lookupSequence_IO = getOEIS seqSearchURI

-- | @extend xs ext@ returns the maximal suffix of @ext@ of which @xs@ is a
-- prefix, or @xs@ if @xs@ is not a prefix of any suffixes of @ext@. It is
-- guaranteed that
--
-- > forall xs ext. xs `isPrefixOf` (extend xs ext)
extend :: SequenceData -> SequenceData -> SequenceData
extend xs ext = fromMaybe xs . listToMaybe . filter (xs `isPrefixOf`) $ tails ext

baseSearchURI :: String
baseSearchURI = "http://oeis.org/search?n=1&fmt=text&q="

idSearchURI :: String -> String
idSearchURI n = baseSearchURI ++ "id:" ++ n

seqSearchURI :: SequenceData -> String
seqSearchURI xs = baseSearchURI ++ intercalate "," (map show xs)

data LookupError = LookupError deriving Show

getOEIS :: (a -> String) -> a -> IO (Maybe OEISSequence)
getOEIS toURI key = case parseURI (toURI key) of
                      Nothing  -> return Nothing
                      Just uri -> do content <- get uri
                                     case content of
                                       (Left LookupError) -> return Nothing
                                       (Right text) -> return $ parseOEIS text

get :: URI -> IO (Either LookupError String)
get uri = do
    eresp <- simpleHTTP (request uri)
    case eresp of
      (Left _) -> return (Left LookupError)
      (Right resp) -> case rspCode resp of
                       (2,0,0) -> return (Right $ rspBody resp)
                       _ -> return (Left LookupError)

request :: URI -> Request String
request uri = Request{ rqURI = uri,
                       rqMethod = GET,
                       rqHeaders = [],
                       rqBody = "" }

-----------------------------------------------------------

-- | Programming language that some code to generate the sequence is written
-- in. The only languages indicated natively by the OEIS database are
-- Mathematica and Maple; any other languages will be listed (usually in
-- parentheses) at the beginning of the actual code snippet.
data Language = Mathematica | Maple | Other deriving Show

-- | OEIS keywords. For more information on the meaning of each keyword, see
-- <http://oeis.org/eishelp2.html#RK>.
data Keyword = Base | Bref | Changed | Cofr | Cons | Core | Dead | Dumb | Dupe |
               Easy | Eigen | Fini | Frac | Full | Hard | More | Mult |
               New | Nice | Nonn | Obsc | Sign | Tabf | Tabl | Uned |
               Unkn | Walk | Word
       deriving (Eq,Show,Read)

readKeyword :: String -> Keyword
readKeyword = read . capitalize

capitalize :: String -> String
capitalize ""     = ""
capitalize (c:cs) = toUpper c : map toLower cs

-- | Data structure for storing an OEIS entry. For more information on the
-- various components, see <http://oeis.org/eishelp2.html>.

data OEISSequence =
  OEIS { catalogNums  :: [String],
         -- ^ Catalog number(s), e.g. A000040, N1425. (%I)
         sequenceData :: SequenceData,
         -- ^ The actual sequence data (or absolute values of the sequence data in the case of signed sequences).  (%S,T,U)
         signedData   :: SequenceData,
         -- ^ Signed sequence data (empty for sequences with all positive entries).  (%V,W,X)
         description  :: String,
         -- ^ Short description of the sequence. (%N)
         references   :: [String],
         -- ^ List of academic references. (%D)
         links        :: [String],
         -- ^ List of links to more information on the web. (%H)
         formulas     :: [String],
         -- ^ Formulas or equations involving the sequence. (%F)
         xrefs        :: [String],
         -- ^ Cross-references to other sequences. (%Y)
         author       :: String,
         -- ^ Author who input the sequence into the database. (%A)
         offset       :: Int,
         -- ^ Subscript\/index of the first term. (%O)
         firstGT1     :: Int,
         -- ^ Index of the first term \> 1.  (%O)
         programs     :: [(Language,String)],
         -- ^ Code that can be used to generate the sequence. (%p,t,o)
         extensions   :: [String],
         -- ^ Corrections, extensions, or edits. (%E)
         examples     :: [String],
         -- ^ Examples. (%e)
         keywords     :: [Keyword],
         -- ^ Keywords. (%K)
         comments     :: [String]
         -- ^ Comments. (%C)
       }  deriving Show

emptyOEIS :: OEISSequence
emptyOEIS = OEIS [] [] [] "" [] [] [] [] "" 0 0 [] [] [] [] []

addElement :: (Char, String) -> OEISSequence -> OEISSequence
addElement ('I', x) c = c { catalogNums = words x }
addElement (t, x)   c | t `elem` "STU" = c { sequenceData = nums ++ sequenceData c }
    where nums = map read $ csvItems x
addElement (t, x)   c | t `elem` "VWX" = c { signedData = nums ++ signedData c }
    where nums = map read $ csvItems x
addElement ('N', x) c = c { description = x                  }
addElement ('D', x) c = c { references  = x : references c }
addElement ('H', x) c = c { links       = x : links c      }
addElement ('F', x) c = c { formulas    = x : formulas c   }
addElement ('Y', x) c = c { xrefs       = x : xrefs c      }
addElement ('A', x) c = c { author      = x                  }
addElement ('O', x) c = c { offset      = read o
                          , firstGT1    = read f }
  where (o,f) = second tail . span (/=',') $ x
addElement ('p', x) c = c { programs    = (Mathematica, x) :
                                            programs c     }
addElement ('t', x) c = c { programs    = (Maple, x) :
                                            programs c     }
addElement ('o', x) c = c { programs    = (Other, x) :
                                            programs c     }
addElement ('E', x) c = c { extensions  = x : extensions c }
addElement ('e', x) c = c { examples    = x : examples c   }
addElement ('K', x) c = c { keywords    = parseKeywords x    }
addElement ('C', x) c = c { comments    = x : comments c   }
addElement _ c = c

parseOEIS :: String -> Maybe OEISSequence
parseOEIS x = if "No results." `isPrefixOf` (ls!!3)
                then Nothing
                else Just . foldl' (flip addElement) emptyOEIS . reverse . parseRawOEIS $ ls'
    where ls = lines x
          ls' = init . drop 5 $ ls

parseRawOEIS :: [String] -> [(Char, String)]
parseRawOEIS = map parseItem . combineConts

parseKeywords :: String -> [Keyword]
parseKeywords = map readKeyword . csvItems

csvItems :: String -> [String]
csvItems "" = []
csvItems x = item : others
    where (item, rest) = span (/=',') x
          others = csvItems $ del ',' rest

del :: Char -> String -> String
del _ ""     = ""
del c (x:xs) | c==x      = xs
             | otherwise = x:xs

parseItem :: String -> (Char, String)
parseItem s = (c, str)
    where ( '%':c:_ , rest) = splitWord s
          (_, str )    = if c == 'I' then ("", rest)
                                     else splitWord rest

combineConts :: [String] -> [String]
combineConts (s@('%':_:_) : ss) =
  uncurry (:) . (joinConts s *** combineConts) . break isItem $ ss
combineConts ss = ss

splitWord :: String -> (String, String)
splitWord = second trimLeft . break isSpace

isItem :: String -> Bool
isItem x = not (null x) && '%' == head x

joinConts :: String -> [String] -> String
joinConts s conts = s ++ concatMap trimLeft conts

trimLeft :: String -> String
trimLeft = dropWhile isSpace

{- $sample

Suppose we are interested in answering the question, \"how many distinct binary
trees are there with exactly 20 nodes?\" Some naive code to answer this
question might be as follows:

> import Data.List (genericLength)
>
> -- data-less binary trees.
> data BTree = Empty | Fork BTree BTree  deriving Show
>
> -- A list of all the binary trees with exactly n nodes.
> listTrees :: Int -> [BTree]
> listTrees 0 = [Empty]
> listTrees n = [Fork left right |
>                k <- [0..n-1],
>                left <- listTrees k,
>                right <- listTrees (n-1-k) ]
>
> countTrees :: Int -> Integer
> countTrees = genericLength . listTrees

The problem, of course, is that @countTrees@ is horribly inefficient:

@
*Main> :set +s
*Main> countTrees 5
42
(0.00 secs, 0 bytes)
*Main> countTrees 10
16796
(0.47 secs, 27513240 bytes)
*Main> countTrees 12
208012
(7.32 secs, 357487720 bytes)
*Main> countTrees 13
*** Exception: stack overflow
@

There's really no way we can evaluate @countTrees 20@. The solution? Cheat!

> import Math.OEIS
>
> -- countTrees works ok up to 10 nodes.
> -- [1,2,5,14,42,132,429,1430,4862,16796]
> smallTreeCounts = map countTrees [0..10]
>
> -- now, extend the sequence via the OEIS!
> treeCounts = extendSequence smallTreeCounts

Now we can answer the question:

> *Main> treeCounts !! 20
> 6564120420

Sweet.  Of course, to have any sort of confidence in our answer, more research
is required! Let's see what combinatorial goodness we have stumbled across.

@
*Main> description \`fmap\` lookupSequence smallTreeCounts
Just \"Catalan numbers: C(n) = binomial(2n,n)\/(n+1) = (2n)!\/(n!(n+1)!). Also called Segner numbers.\"
@

Catalan numbers, interesting.  And a nice formula we could use to code up a
/real/ solution! Hmm, where can we read more about these so-called \'Catalan
numbers\'?

@
*Main> (head . references) \`fmap\` lookupSequence smallTreeCounts
Just [\"A. Bernini, F. Disanto, R. Pinzani and S. Rinaldi, Permutations defining convex permutominoes, preprint, 2007.\"]
*Main> (head . links) \`fmap\` lookupSequence smallTreeCounts
Just [\"N. J. A. Sloane, \<a href=\\\"http:\/\/www.research.att.com\/~njas\/sequences\/b000108.txt\\\"\>The first 200 Catalan numbers\<\/a\>\"]
@

And so on. Reams of collected mathematical knowledge at your fingertips! You
must promise only to use this power for Good.
-}

{-# ANN module "HLint: ignore Use camelCase" #-}
