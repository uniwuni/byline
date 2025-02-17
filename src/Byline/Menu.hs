-- |
--
-- Copyright:
--   This file is part of the package byline. It is subject to the
--   license terms in the LICENSE file found in the top-level
--   directory of this distribution and at:
--
--     https://github.com/pjones/byline
--
--   No part of this package, including this file, may be copied,
--   modified, propagated, or distributed except according to the
--   terms contained in the LICENSE file.
--
-- License: BSD-2-Clause
module Byline.Menu
  ( -- * Menus with Tab Completion
    -- $usage

    -- * Building a Menu
    Menu,
    menu,
    menuBanner,
    menuPrefix,
    menuSuffix,
    FromChoice,
    menuFromChoiceFunc,

    -- * Prompting with a Menu
    askWithMenu,
    askWithMenuRepeatedly,
    Choice (..),
    defaultFromChoice,
    -- * Re-exports
    module Byline,
  )
where

import Byline
import Byline.Completion
import Byline.Internal.Stylized (RenderMode (..), renderText)
import qualified Data.Text as Text
import Relude.Extra.Map
import Text.Printf (printf)

-- | Opaque type representing a menu containing items of type @a@.
--
-- @since 1.0.0.0
data Menu a = Menu
  { -- | Menu items.
    _menuItems :: NonEmpty a,
    -- | Banner printed before menu.
    _menuBanner :: Maybe (Stylized Text),
    -- | Stylize an item's index.
    _menuItemPrefix :: Int -> Stylized Text,
    -- | Printed after an item's index.
    _menuItemSuffix :: Stylized Text,
    -- | Printed before the prompt.
    _menuBeforePrompt :: Maybe (Stylized Text),
    -- | 'FromChoice' function.
    _menuItemFromChoiceFunc :: FromChoice a
  }

instance Foldable Menu where
  foldMap f Menu {..} = foldMap f _menuItems
  toList Menu {..} = toList _menuItems
  null _ = False
  length Menu {..} = length _menuItems

-- | A type representing the choice made by a user while working with
-- a menu.
--
-- @since 1.0.0.0
data Choice a
  = -- | User picked a menu item.
    Match a
  | -- | User entered text that doesn't match an item.
    Other Text
  deriving (Show, Eq, Functor, Foldable, Traversable)

-- | A function that is given the input from a user while working in a
-- menu and should translate that into a 'Choice'.
--
-- The @Map@ contains the menu item indexes/prefixes (numbers or
-- letters) and the items themselves.
--
-- The default 'FromChoice' function allows the user to select a menu
-- item by typing its index or part of its textual representation.  As
-- long as input from the user is a unique prefix of one of the menu
-- items then that item will be returned.
--
-- @since 1.0.0.0
type FromChoice a = Menu a -> Map Text a -> Text -> Choice a

-- | Default prefix generator.  Creates numbers aligned for two-digit
-- prefixes.
--
-- @since 1.0.0.0
numbered :: Int -> Stylized Text
numbered = text . Text.pack . printf "%2d"

-- | Helper function to produce a list of menu items matching the
-- given user input.
--
-- @since 1.0.0.0
matchOnPrefix :: ToStylizedText a => Menu a -> Text -> [a]
matchOnPrefix config input =
  filter prefixCheck (toList $ _menuItems config)
  where
    asText i = renderText Plain (toStylizedText i)
    prefixCheck i = input `Text.isPrefixOf` asText i

-- | Default 'FromChoice' function.  Checks to see if the user has input
-- a unique prefix for a menu item (matches the item text) or selected
-- one of the generated item prefixes (such as those generated by the
-- internal @numbered@ function).
--
-- @since 1.0.0.0
defaultFromChoice :: forall a. ToStylizedText a => FromChoice a
defaultFromChoice config prefixes input =
  case uniquePrefix <|> lookup cleanInput prefixes of
    Nothing -> Other input
    Just match -> Match match
  where
    cleanInput :: Text
    cleanInput = Text.strip input
    uniquePrefix :: Maybe a
    uniquePrefix =
      let matches = matchOnPrefix config cleanInput
       in if length matches == 1
            then listToMaybe matches
            else Nothing

-- | Default completion function.  Matches all of the menu items.
--
-- @since 1.0.0.0
defaultCompFunc :: (Applicative m, ToStylizedText a) => Menu a -> CompletionFunc m
defaultCompFunc config (left, _) =
  pure ("", completions matches)
  where
    -- All matching menu items.
    matches =
      if Text.null left
        then toList (_menuItems config)
        else matchOnPrefix config left
    -- Convert a menu item to a String.
    asText i = renderText Plain (toStylizedText i)
    -- Convert menu items into Completion values.
    completions = map (\i -> Completion (asText i) (asText i) True)

-- | Create a 'Menu' by giving a list of menu items and a function
-- that can convert those items into stylized text.
--
-- @since 1.0.0.0
menu :: ToStylizedText a => NonEmpty a -> Menu a
menu items =
  Menu
    { _menuItems = items,
      _menuBanner = Nothing,
      _menuItemPrefix = numbered,
      _menuItemSuffix = text ") ",
      _menuBeforePrompt = Nothing,
      _menuItemFromChoiceFunc = defaultFromChoice
    }

-- | Change the banner of a menu.  The banner is printed just before
-- the menu items are displayed.
--
-- @since 1.0.0.0
menuBanner :: ToStylizedText b => b -> Menu a -> Menu a
menuBanner b m = m {_menuBanner = Just (toStylizedText b)}

-- | Change the prefix function.  The prefix function should generate
-- unique, stylized text that the user can use to select a menu item.
-- The default prefix function numbers the menu items starting with 1.
--
-- @since 1.0.0.0
menuPrefix :: (Int -> Stylized Text) -> Menu a -> Menu a
menuPrefix f m = m {_menuItemPrefix = f}

-- | Change the menu item suffix.  It is displayed directly after the
-- menu item prefix and just before the menu item itself.
--
-- Default: @") "@
--
-- @since 1.0.0.0
menuSuffix :: Stylized Text -> Menu a -> Menu a
menuSuffix s m = m {_menuItemSuffix = s}

-- | Change the 'FromChoice' function.  The function should
-- compare the user's input to the menu items and their assigned
-- prefix values and return a 'Choice'.
--
-- @since 1.0.0.0
menuFromChoiceFunc :: FromChoice a -> Menu a -> Menu a
menuFromChoiceFunc f m = m {_menuItemFromChoiceFunc = f}

-- | Ask the user to choose an item from a menu.  The menu will only
-- be shown once and the user's choice will be returned in a 'Choice'
-- value.
--
-- If you want to force the user to only choose from the displayed
-- menu items you should use 'askWithMenuRepeatedly' instead.
--
-- @since 1.0.0.0
askWithMenu ::
  (MonadByline m, ToStylizedText a, ToStylizedText b) =>
  -- | The 'Menu' to display.
  Menu a ->
  -- | The prompt.
  b ->
  -- | The 'Choice' the user selected.
  m (Choice a)
askWithMenu m prompt =
  pushCompletionFunction (defaultCompFunc m)
    *> go
    <* popCompletionFunction
  where
    go = do
      prefixes <- displayMenu
      answer <- askLn prompt (Just firstItem)
      pure (_menuItemFromChoiceFunc m m prefixes answer)
    -- The default menu item.
    firstItem = Text.strip (renderText Plain (_menuItemPrefix m 1))
    -- Print the entire menu.
    displayMenu = do
      maybe pass ((<> text "\n") >>> sayLn) (_menuBanner m)
      cache <- foldlM listItem mempty (zip [1 ..] (toList $ _menuItems m))
      sayLn (maybe mempty (text "\n" <>) (_menuBeforePrompt m))
      pure cache
    -- Print a menu item and cache its prefix in a Map.
    listItem cache (index, item) = do
      let bullet = _menuItemPrefix m index
          rendered = renderText Plain bullet
      sayLn $
        mconcat
          [ text "  ", -- Indent.
            bullet, -- Unique identifier.
            _menuItemSuffix m, -- Spacer or marker.
            toStylizedText item -- The item.
          ]
      pure (one (Text.strip rendered, item) <> cache)

-- | Like 'askWithMenu' except that arbitrary input is not allowed.
-- If the user doesn't correctly select a menu item then the menu will
-- be repeated and an error message will be displayed.
--
-- @since 1.0.0.0
askWithMenuRepeatedly ::
  (MonadByline m, ToStylizedText a, ToStylizedText b, ToStylizedText e) =>
  -- | The 'Menu' to display.
  Menu a ->
  -- | The prompt.
  b ->
  -- | Error message when the user tried to select a non-menu item.
  e ->
  -- | The 'Choice' the user selected.
  m a
askWithMenuRepeatedly m prompt errprompt = go m
  where
    go config = do
      answer <- askWithMenu config prompt
      case answer of
        Other _ -> go (config {_menuBeforePrompt = Just (toStylizedText errprompt)})
        Match x -> pure x

-- $usage
--
-- Menus are used to provide the user with a choice of acceptable
-- values.  Each choice is labeled to make it easier for a user to
-- select it, or the user may enter text that does not correspond to
-- any of the menus items.
--
-- For an example see the @menu.hs@ file in the @examples@ directory.
