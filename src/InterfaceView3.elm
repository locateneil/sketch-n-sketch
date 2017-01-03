module InterfaceView3 exposing (view)

-- Sketch-n-Sketch Libraries ---------------------------------------------------

import Config exposing (params) -- TODO remove
import ExamplesGenerated as Examples
import Utils
import HtmlUtils exposing (handleEventAndStop)
import Either exposing (..)

import InterfaceModel as Model exposing
  ( Msg(..), Model, Tool(..), ShapeToolKind(..), Mode(..)
  , Caption(..), MouseMode(..)
  , mkLive_
  , DialogBox(..)
  )
import InterfaceController as Controller
import Layout
import Canvas
import LangSvg exposing (attr)
import Sync

-- Elm Libraries ---------------------------------------------------------------

import Set
import Dict

import Svg exposing (Svg)
import Svg.Events exposing (onMouseDown, onMouseUp, onMouseOver, onMouseOut)
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events exposing
  ( onClick, onInput, on
  , onWithOptions, defaultOptions
  )
import Html.Lazy
import Json.Decode


--------------------------------------------------------------------------------

pixels n = toString n ++ "px"

imgPath s = "img/" ++ s


--------------------------------------------------------------------------------
-- Configuration Parameters

showRawShapeTools = False


--------------------------------------------------------------------------------
-- Top-Level View Function

view : Model -> Html Msg
view model =
  let layout = Layout.computeLayout model in

  let fileTools = fileToolBox model layout in
  let codeTools = codeToolBox model layout in
  let drawTools = drawToolBox model layout in
  let attributeTools = attributeToolBox model layout in
  let blobTools = blobToolBox model layout in
  let outputTools = outputToolBox model layout in

  let
    dialogBoxes =
      [ fileNewDialogBox model
      , fileSaveAsDialogBox model
      , fileOpenDialogBox model
      , alertSaveDialogBox model
      , importCodeDialogBox model
      ]
  in

  let
    needsSaveString =
      if model.needsSave then
        "true"
      else
        "false"
    onbeforeunloadDataElement =
      Html.input
        [ Attr.type_ "hidden"
        , Attr.id "onbeforeunload-data"
        , Attr.attribute "data-needs-save" needsSaveString
        , Attr.attribute "data-filename" (Model.prettyFilename model)
        ]
        []
  in

  let animationTools =
    if model.slideCount > 1 || model.movieCount > 1
    then [ animationToolBox model layout ]
    else [] in

  let codeBox =
    if model.basicCodeBox
      then basicCodeBox model layout.codeBox
      else aceCodeBox model layout.codeBox in

  let outputBox = outputArea model layout in

  let resizeCodeBox =
    resizeWidget "resizeCodeBox" model layout Layout.getPutCodeBox
       (layout.codeBox.left + layout.codeBox.width)
       (layout.codeBox.top + layout.codeBox.height) in

  let resizeCanvas =
    resizeWidget "resizeCanvas" model layout Layout.getPutCanvas
       layout.canvas.left
       layout.canvas.top in

  let caption = captionArea model layout in

  let everything = -- z-order in decreasing order

     -- bottom-most
     [ onbeforeunloadDataElement
     , codeBox, outputBox

     -- toolboxes in reverse order
     , outputTools] ++ animationTools ++
     [ blobTools, attributeTools, drawTools
     , codeTools, fileTools

     -- top-most
     , resizeCodeBox
     , resizeCanvas
     , caption
     ] ++ dialogBoxes
  in

  Html.div
    [ Attr.id "containerDiv"
    , Attr.style
        [ ("position", "fixed")
        , ("width", pixels model.dimensions.width)
        , ("height", pixels model.dimensions.height)
        , ("background", "white")
        ]
    ]
    everything


--------------------------------------------------------------------------------
-- Tool Boxes

fileToolBox model layout =
  toolBox model "fileToolBox" Layout.getPutFileToolBox layout.fileTools
    [ fileIndicator model
    , fileNewDialogBoxButton
    , fileSaveAsDialogBoxButton
    , fileSaveButton model
    , fileOpenDialogBoxButton
    , Html.br [] []
    , exportCodeButton
    , exportSvgButton
    , Html.br [] []
    , importCodeButton
    , importSvgButton
    ]

codeToolBox model layout =
  toolBox model "codeToolBox" Layout.getPutCodeToolBox layout.codeTools
    [ runButton
    , undoButton model
    , redoButton model
    , cleanButton model
    ]

drawToolBox model layout =
  toolBox model "drawToolBox" Layout.getPutDrawToolBox layout.drawTools
    [ toolButton model Cursor
    , toolButton model (Line Raw)
    , toolButton model (Rect Raw)
    , toolButton model (Oval Raw)
    , toolButton model (Poly Raw)
    , toolButton model (Path Raw)
    ]

attributeToolBox model layout =
  toolBox model "attributeToolBox" Layout.getPutAttributeToolBox layout.attributeTools
    [ relateButton model "Dig Hole" Controller.msgDigHole
    , relateButton model "Make Equal" Controller.msgMakeEqual
    ]

blobToolBox model layout =
  toolBox model "blobToolBox" Layout.getPutBlobToolBox layout.blobTools
    [ groupButton model "Dupe" Controller.msgDuplicateBlobs
    , groupButton model "Merge" Controller.msgMergeBlobs
    , groupButton model "Group" Controller.msgGroupBlobs
    , groupButton model "Abs" Controller.msgAbstractBlobs
    ]

outputToolBox model layout =
  toolBox model "outputToolBox" Layout.getPutOutputToolBox layout.outputTools
    [ -- codeBoxButton model
      heuristicsButton model
    , outputButton model
    , ghostsButton model
    ]

animationToolBox model layout =
  toolBox model "animationToolBox" Layout.getPutAnimationToolBox layout.animationTools
    [ previousSlideButton model
    , previousMovieButton model
    , pauseResumeMovieButton model
    , nextMovieButton model
    , nextSlideButton model
    ]

toolBox model id (getOffset, putOffset) leftRightTopBottom elements =
  Html.div
    [ Attr.id id
    , Attr.style <|
        [ ("position", "fixed")
        , ("padding", "0px 0px 0px 15px")
        , ("background", Layout.strInterfaceColor) -- "#444444")
        , ("border-radius", "10px 0px 0px 10px")
        , ("box-shadow", "6px 6px 3px #888888")
        , ("cursor", "move")
        ] ++ Layout.fixedPosition leftRightTopBottom
    , onMouseDown <| Layout.dragLayoutWidgetTrigger (getOffset model) putOffset
    ]
    elements


--------------------------------------------------------------------------------
-- Code Box

aceCodeBox model dim =
  Html.div
    [ Attr.id "editor"
    , Attr.style [ ("position", "absolute")
                 , ("width", pixels dim.width)
                 , ("height", pixels dim.height)
                 , ("left", pixels Layout.windowPadding)
                 , ("top", pixels Layout.windowPadding)
                 , ("pointer-events", "auto")
                 ]
    ]
    [ ]
    {- Html.Lazy.lazy ... -}

basicCodeBox model dim =
  textArea model.code <|
    [ onInput Controller.msgCodeUpdate
    , Attr.style [ ("width", pixels dim.width)
                 ]
    ]

textArea text attrs =
  let innerPadding = 4 in
  -- NOTE: using both Attr.value and Html.text seems to allow read/write...
  let commonAttrs =
    [ Attr.spellcheck False
    , Attr.value text
    , Attr.style
        [ ("font-family", params.mainSection.codebox.font)
        , ("font-size", params.mainSection.codebox.fontSize)
        , ("border", params.mainSection.codebox.border)
        , ("whiteSpace", "pre")
        , ("height", "100%")
        , ("resize", "none")
        , ("overflow", "auto")
        -- Horizontal Scrollbars in Chrome
        , ("word-wrap", "normal")
        -- , ("background-color", "whitesmoke")
        , ("background-color", "white")
        , ("padding", toString innerPadding ++ "px")
        -- Makes the 100% for width/height work as intended
        , ("box-sizing", "border-box")
        ]
    ]
  in
  Html.textarea (commonAttrs ++ attrs) [ Html.text text ]


--------------------------------------------------------------------------------
-- Output Box

outputArea model layout =
  let output =
    case (model.errorBox, model.mode) of
      (Just errorMsg, _) ->
        textArea errorMsg
          [ Attr.style [ ("width", pixels layout.canvas.width) ] ]
      (Nothing, Print svgCode) ->
        textArea svgCode
          [ Attr.style [ ("width", pixels layout.canvas.width) ] ]
      (Nothing, _) ->
        Canvas.build layout.canvas.width layout.canvas.height model
  in
  Html.div
     [ Attr.id "outputArea"
     , Attr.style
         [ ("width", pixels layout.canvas.width)
         , ("height", pixels layout.canvas.height)
         , ("position", "fixed")
         , ("border", params.mainSection.canvas.border)
         , ("left", pixels layout.canvas.left)
         , ("top", pixels layout.canvas.top)
         , ("background", "white")
         , ("border-radius", "0px 10px 10px 10px")
         , ("box-shadow", "10px 10px 5px #888888")
         ]
     ]
     [ output ]


--------------------------------------------------------------------------------
-- Resizing Widgets

rResizeWidgetBall = 5

resizeWidget id model layout (getOffset, putOffset) left top =
  Svg.svg
    [ Attr.id id
    , Attr.style
        [ ("position", "fixed")
        , ("left", pixels (left - 2 * rResizeWidgetBall))
        , ("top", pixels (top - 2 * rResizeWidgetBall))
        , ("width", pixels (4 * rResizeWidgetBall))
        , ("height", pixels (4 * rResizeWidgetBall))
        ]
    ]
    [ flip Svg.circle [] <|
        [ attr "stroke" "black" , attr "stroke-width" "2px"
        , attr "fill" Layout.strButtonTopColor
        , attr "r" (pixels rResizeWidgetBall)
        , attr "cx" (toString (2 * rResizeWidgetBall))
        , attr "cy" (toString (2 * rResizeWidgetBall))
        , attr "cursor" "move"
        , onMouseDown <| Layout.dragLayoutWidgetTrigger (getOffset model) putOffset
        ]
    ]


--------------------------------------------------------------------------------
-- Buttons

type ButtonKind = Regular | Selected | Unselected

htmlButton text onClickHandler btnKind disabled =
  let color =
    case btnKind of
      Regular    -> "white"
      Unselected -> "white"
      Selected   -> "lightgray"
  in
  let commonAttrs =
    [ Attr.disabled disabled
    , Attr.style [ ("font", params.mainSection.widgets.font)
                 , ("fontSize", params.mainSection.widgets.fontSize)
                 , ("height", pixels Layout.buttonHeight)
                 , ("background", color)
                 , ("user-select", "none")
                 ] ]
  in
  Html.button
    (commonAttrs ++
      [ handleEventAndStop "mousedown" Controller.msgNoop
      , onClick onClickHandler
      ])
    [ Html.text text ]

runButton =
  htmlButton "Run" Controller.msgRun Regular False

cleanButton model =
  let disabled =
    case model.mode of
      Live _ -> False
      _      -> True
  in
  htmlButton "Clean Up" Controller.msgCleanCode Regular disabled

undoButton model =
  let past = Tuple.first model.history in
  htmlButton "Undo" Controller.msgUndo Regular (List.length past <= 1)

redoButton model =
  let future = Tuple.second model.history in
  htmlButton "Redo" Controller.msgRedo Regular (List.length future == 0)

heuristicsButton model =
  let foo old =
    let so = old.syncOptions in
    let so_ = { so | feelingLucky = Sync.toggleHeuristicMode so.feelingLucky } in
    case old.mode of
      Live _ ->
        case mkLive_ so_ old.slideNumber old.movieNumber old.movieTime old.inputExp of
          Ok m_ -> { old | syncOptions = so_, mode = m_ }
          Err s -> { old | syncOptions = so_, errorBox = Just s }
      _ -> { old | syncOptions = so_ }
  in
  let yesno =
    let hm = model.syncOptions.feelingLucky in
    if hm == Sync.heuristicsNone then "None"
    else if hm == Sync.heuristicsFair then "Fair"
    else "Biased"
  in
  htmlButton ("[Heuristics] " ++ yesno)
    (Msg "Toggle Heuristics" foo) Regular False

outputButton model =
  let cap =
     case model.mode of
       Print _ -> "[Out] SVG"
       _       -> "[Out] Canvas"
  in
  htmlButton cap Controller.msgToggleOutput Regular False

ghostsButton model =
  let cap =
     case model.showGhosts of
       True  -> "[Ghosts] Shown"
       False -> "[Ghosts] Hidden"
  in
  let foo old =
    let showGhosts_ = not old.showGhosts in
    let mode_ =
      case old.mode of
        Print _ -> Print (LangSvg.printSvg showGhosts_ old.slate)
        _       -> old.mode
    in
    { old | showGhosts = showGhosts_, mode = mode_ }
  in
  htmlButton cap (Msg "Toggle Ghosts" foo) Regular False

codeBoxButton model =
  let text = "[Code Box] " ++ if model.basicCodeBox then "Basic" else "Fancy" in
  htmlButton text Controller.msgToggleCodeBox Regular False

toolButton model tool =
  let capStretchy s = if showRawShapeTools then "BB" else s in
  let capSticky = Utils.uniPlusMinus in -- Utils.uniDelta in
  let capRaw = "(Raw)" in
  let cap = case tool of
    Cursor        -> "Cursor"
    Line Raw      -> "Line"
    Rect Raw      -> "Rect"
    Rect Stretchy -> capStretchy "Box"
    Oval Raw      -> "Ellipse"
    Oval Stretchy -> capStretchy "Oval"
    Poly Raw      -> "Polygon"
    -- Poly Stretchy -> capStretchy "Polygon"
    Poly Stretchy -> capStretchy "Poly"
    Poly Sticky   -> capSticky
    Path Raw      -> "Path"
    Path Stretchy -> capStretchy "Path"
    Path Sticky   -> capSticky
    Text          -> "Text"
    HelperLine    -> "(Rule)"
    HelperDot     -> "(Dot)"
    Lambda        -> Utils.uniLambda
    _             -> Debug.crash ("toolButton: " ++ toString tool)
  in
  -- TODO temporarily disabling a couple tools
  let (btnKind, disabled) =
    case (model.tool == tool, tool) of
      (True, _)            -> (Selected, False)
      (False, Path Sticky) -> (Regular, True)
      (False, _)           -> (Unselected, False)
  in
  htmlButton cap (Msg cap (\m -> { m | tool = tool })) btnKind disabled

relateButton model text handler =
  let noFeatures = Set.isEmpty model.selectedFeatures in
  htmlButton text handler Regular noFeatures

groupButton model text handler =
  let noFeatures = Set.isEmpty model.selectedFeatures in
  let noBlobs = Dict.isEmpty model.selectedBlobs in
  htmlButton text handler Regular (noBlobs || not noFeatures)

previousSlideButton model =
  htmlButton "◀◀" Controller.msgPreviousSlide Regular
    (model.slideNumber == 1 && model.movieNumber == 1)

nextSlideButton model =
  htmlButton "▶▶" Controller.msgNextSlide Regular
    (model.slideNumber == model.slideCount
      && model.movieNumber == model.movieCount)

previousMovieButton model =
  htmlButton "◀" Controller.msgPreviousMovie Regular
    (model.slideNumber == 1 && model.movieNumber == 1)

nextMovieButton model =
  htmlButton "▶" Controller.msgNextMovie Regular
    (model.slideNumber == model.slideCount
      && model.movieNumber == model.movieCount)

pauseResumeMovieButton model =
  let enabled = model.movieTime < model.movieDuration in
  let caption =
    if enabled && not model.runAnimation then "Play"
    else "Pause"
  in
  htmlButton caption Controller.msgPauseResumeMovie Regular (not enabled)

fileNewDialogBoxButton =
  htmlButton "New" (Controller.msgOpenDialogBox New) Regular False

fileSaveAsDialogBoxButton =
  htmlButton "Save As" (Controller.msgOpenDialogBox SaveAs) Regular False

fileSaveButton model =
  htmlButton "Save" Controller.msgSave Regular (not model.needsSave)

fileOpenDialogBoxButton =
  htmlButton "Open" (Controller.msgOpenDialogBox Open) Regular False

closeDialogBoxButton db =
  htmlButton "Close Dialog Box" (Controller.msgCloseDialogBox db) Regular False

exportCodeButton =
  htmlButton "Export Code" Controller.msgExportCode Regular False

importCodeButton =
    htmlButton "Import Code" (Controller.msgOpenDialogBox ImportCode) Regular False

exportSvgButton =
  htmlButton "Export SVG" Controller.msgExportSvg Regular False

importSvgButton =
   htmlButton "Import SVG" Controller.msgNoop Regular True

-- autosaveButton model =
--     let cap = case model.autosave of
--       True  -> "[Autosave] Yes"
--       False -> "[Autosave] No"
--     in
--       htmlButton cap Controller.msgToggleAutosave Regular True

--------------------------------------------------------------------------------
-- Hover Caption

captionArea model layout =
  let (text, color) =
    case (model.caption, model.mode, model.mouseMode) of
      (Just (Hovering zoneKey), Live info, MouseNothing) ->
        case Sync.hoverInfo zoneKey info of
          (line1, Nothing) ->
            (line1 ++ " (INACTIVE)", "red")
          (line1, Just line2) ->
            (line1 ++ " (ACTIVE)\n" ++ line2, "green")

      (Just (LangError err), _, _) ->
        (err, "black")

      _ ->
        if model.slideCount > 1 then
          let
            s1 = toString model.slideNumber ++ "/" ++ toString model.slideCount
            s2 = toString model.movieNumber ++ "/" ++ toString model.movieCount
            s3 = truncateFloat model.movieTime ++ "/" ++ truncateFloat model.movieDuration
          in
          (Utils.spaces ["Slide", s1, ":: Movie", s2, ":: Time", s3], "black")

        else
          ("", "white")

  in
  Html.span
    [ Attr.id "captionArea"
    , Attr.style <|
        [ ("color", color)
        , ("position", "fixed")
        ] ++ Layout.fixedPosition layout.captionArea
    ]
    [ Html.text text ]

truncateFloat : Float -> String
truncateFloat n =
  case String.split "." (toString n) of
    [whole]           -> whole ++ "." ++ String.padRight 1 '0' ""
    [whole, fraction] -> whole ++ "." ++ String.left 1 (String.padRight 1 '0' fraction)
    _                 -> Debug.crash "truncateFloat"

--------------------------------------------------------------------------------
-- Dialog Boxes

dialogBox zIndex width height closable db model elements =
  let
    closeButton =
      if closable then
        [ Html.div
            [ Attr.style
                [ ("text-align", "center")
                , ("padding", "20px")
                ]
            ]
            [ closeDialogBoxButton db ]
        ]
      else
        []
    displayStyle =
      if (Set.member (Model.dbToInt db) model.dialogBoxes) then
        "block"
      else
        "none"
  in
    Html.div
      [ Attr.style
        [ ("position", "fixed")
        , ("top", "50%")
        , ("left", "50%")
        , ("width", width)
        , ("height", height)
        , ("font-family", "sans-serif")
        , ("background-color", "#F8F8F8")
        , ("border", "2px solid " ++ Layout.strInterfaceColor)
        , ("border-radius", "10px")
        , ("box-shadow", "0 0 10px 0 #888888")
        , ("transform", "translateY(-50%) translateX(-50%)")
        , ("margin", "auto")
        , ("z-index", zIndex)
        , ("overflow", "scroll")
        , ("display", displayStyle)
        ]
      ]
      (elements ++ closeButton)

bigDialogBox = dialogBox "100" "85%" "85%"

smallDialogBox = dialogBox "101" "35%" "35%"

fileNewDialogBox model =
  let viewTemplate (name, _) =
        Html.div
          [ Attr.style
              [ ("font-family", "monospace")
              , ("font-size", "1.2em")
              , ("padding", "20px")
              , ("border-bottom", "1px solid black")
              ]
          ]
          [ htmlButton
              name
              (Controller.msgAskNew name model.needsSave)
              Regular
              False
          ]
  in
    bigDialogBox True New model <|
      [ Html.h2
        [ Attr.style
          [ ("padding", "20px")
          , ("margin", "0")
          , ("border-bottom", "1px solid black")
          ]
        ]
        [ Html.text "New..." ]
      ]
        ++ List.map viewTemplate Examples.list

fileSaveAsDialogBox model =
  let saveAsInput =
        Html.div
          [ Attr.style
            [ ("font-family", "monospace")
            , ("font-size", "1.2em")
            , ("padding", "20px")
            , ("text-align", "right")
            ]
          ]
          [ Html.input
              [ Attr.type_ "text"
              , onInput Controller.msgUpdateFilenameInput
              ]
              []
          , Html.text ".little"
          , Html.span
              [ Attr.style
                  [ ("margin-left", "20px")
                  ]
              ]
              [ htmlButton "Save" Controller.msgSaveAs Regular False ]
          ]
  in
    bigDialogBox True SaveAs model <|
      [ Html.h2
        [ Attr.style
          [ ("padding", "20px")
          , ("margin", "0")
          , ("border-bottom", "1px solid black")
          ]
        ]
        [ Html.text "Save As..." ]
      ]
        ++ List.map viewFileIndexEntry model.fileIndex
        ++ [ saveAsInput ]

fileOpenDialogBox model =
  let fileOpenRow filename =
        Html.div
          [ Attr.style
            [ ("font-family", "monospace")
            , ("font-size", "1.2em")
            , ("padding", "20px")
            , ("border-bottom", "1px solid black")
            , ("overflow", "hidden")
            ]
          ]
          [ Html.span []
              [ Html.b [] [ Html.text filename ]
              , Html.text ".little"
              ]
          , Html.span
              [ Attr.style
                  [ ("float", "right")
                  ]
              ]
              [ htmlButton "Open"
                           (Controller.msgAskOpen filename model.needsSave)
                           Regular
                           False
              , Html.span
                  [ Attr.style
                    [ ("margin-left", "50px")
                    ]
                  ]
                  [ htmlButton "Delete"
                               (Controller.msgDelete filename)
                               Regular
                               False
                  ]
              ]
          ]
  in
    bigDialogBox True Open model <|
      [ Html.h2
        [ Attr.style
          [ ("padding", "20px")
          , ("margin", "0")
          , ("border-bottom", "1px solid black")
          ]
        ]
        [ Html.text "Open..." ]
      ]
        ++ List.map fileOpenRow model.fileIndex

viewFileIndexEntry filename =
  Html.div
    [ Attr.style
        [ ("font-family", "monospace")
        , ("font-size", "1.2em")
        , ("padding", "20px")
        , ("border-bottom", "1px solid black")
        ]
    ]
    [ Html.span []
        [ Html.b [] [ Html.text filename ]
        , Html.text ".little"
        ]
    ]

fileIndicator model =
  let
    filenameHtml =
      Html.text (Model.prettyFilename model)
    wrapper =
      if model.needsSave then
        Html.i [] [ filenameHtml, Html.text " *" ]
      else
        filenameHtml
  in
    Html.div
      [ Attr.style
          [ ("color", "white")
          , ("font-family", "sans-serif")
          , ("padding", "7px")
          ]
      ]
      [ Html.u [] [ Html.text "File" ]
      , Html.text ": "
      , wrapper
      ]

alertSaveDialogBox model =
  smallDialogBox False AlertSave model
    [ Html.h2
        [ Attr.style
          [ ("color", "#550000")
          , ("padding", "20px")
          , ("margin", "0")
          , ("border-bottom", "1px solid black")
          ]
        ]
        [ Html.text "Warning" ]
    , Html.div
        [ Attr.style
            [ ("padding", "20px")
            ]
        ]
        [ Html.i []
            [ Html.text <| Model.prettyFilename model ]
        , Html.text
            " has unsaved changes. Are you sure that you would like to continue?"
        , Html.br [] []
        , Html.br [] []
        , Html.b []
            [ Html.text "You will lose your unsaved changes." ]
        , Html.br [] []
        , Html.br [] []
        , Html.div
            [ Attr.style
                [ ("float", "right")
                , ("margin-bottom", "20px")
                ]
            ]
            [ htmlButton "No" Controller.msgCancelFileOperation Regular False
            , Html.span
                [ Attr.style
                  [ ("margin-left", "50px")
                  ]
                ]
                [ htmlButton "Yes" Controller.msgConfirmFileOperation Regular False ]
            ]
        ]
    ]

importCodeDialogBox model =
  bigDialogBox True ImportCode model
      [ Html.h2
          [ Attr.style
            [ ("padding", "20px")
            , ("margin", "0")
            , ("border-bottom", "1px solid black")
            ]
          ]
          [ Html.text "Import Code..." ]
      , Html.div
          [ Attr.style
              [ ("padding", "20px")
              , ("text-align", "center")
              ]
          ]
          [ Html.input
              [ Attr.type_ "file"
              , Attr.id Model.importCodeFileInputId
              ]
              []
          , htmlButton
              "Import"
              (Controller.msgAskImportCode model.needsSave)
              Regular
              False
          ]
      ]
