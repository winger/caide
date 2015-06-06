{-# LANGUAGE OverloadedStrings #-}

module Caide.Features.Codelite(
      feature
) where


import Control.Applicative ((<$>))
import Control.Monad (forM_, when)
import Control.Monad.State.Strict (modify, gets)
import Control.Monad.State (liftIO)
import Data.List ((\\), sort)
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import qualified Data.Text.IO.Util as T

import Filesystem (isFile, readTextFile, writeTextFile, listDirectory, createDirectory)
import Filesystem.Path.CurrentOS (fromText, decodeString, encodeString)
import Filesystem.Path ((</>), basename, hasExtension)
import qualified Filesystem.Path as F

import qualified System.FilePath
import Filesystem.Util (listDir, pathToText)

import Text.XML.Light (parseXML, Content(..))
import Text.XML.Light.Cursor

import Caide.Types
import Caide.Xml
import Caide.Configuration (readProblemState, getActiveProblem)

feature :: Feature
feature =  noOpFeature
    { onProblemCodeCreated = generateProject
    , onProblemCheckedOut = generateProject
    , onProblemRemoved = const generateWorkspace
    }

generateProject :: ProblemID -> CaideIO ()
generateProject probId = do
    hProblem <- readProblemState probId
    lang <- getProp hProblem "problem" "language"
    when (lang `elem` ["simplecpp", "cpp", "c++" :: T.Text]) $ do
        croot <- caideRoot

        let projectDir = croot </> fromText probId
            needLibrary = lang `elem` ["cpp", "c++"]
            libProjectDir  = croot </> "cpplib"
            libProjectFile = libProjectDir </> "cpplib.project"

        when needLibrary $ do
            libProjectExists <- liftIO $ isFile libProjectFile
            xmlCursor <- if libProjectExists
                then do
                    doc <- liftIO $ parseXML <$> readTextFile libProjectFile
                    let Just cursor = fromForest doc
                    return cursor
                else do
                    xmlString <- liftIO $ do
                        createDirectory True libProjectDir
                        readTextFile $ croot </> "templates" </> "codelite_project_template.project"
                    let doc = parseXML xmlString
                        Just cursor = fromForest doc
                        files = []
                        includePaths = ["."]
                        libs = []
                        libraryPaths = []
                        deps = []
                        transformed = runXmlTransformation
                            (generateProjectXML "cpplib" "Static Library" files includePaths libraryPaths libs deps >>
                             setOutputFile "$(IntermediateDirectory)/lib$(ProjectName).a")
                            cursor
                    case transformed of
                        Left errorMessage -> throw . T.concat $ ["Couldn't create cpplib.project: ", errorMessage]
                        Right (_, xml)    -> do
                            liftIO $ T.putStrLn "cpplib.project for Codelite successfully generated."
                            return xml

            liftIO $ do
                allFiles <- map (makeRelative libProjectDir) . fst <$> listDir libProjectDir
                let files = sort . map pathToText . filter (\f -> f `hasExtension` "h" || f `hasExtension` "cpp") $ allFiles
                    transformed = runXmlTransformation (setSourceFiles files) xmlCursor
                case transformed of
                    Left errorMessage -> do
                        T.putStrLn . T.concat $ ["Couldn't update cpplib.project: ", errorMessage]
                        writeTextFile libProjectFile . T.pack . showXml $ xmlCursor
                    Right (_, xml)    -> writeTextFile libProjectFile . T.pack . showXml $ xml

        generateProjectUnlessExists projectDir probId
            (map (T.append probId) [".cpp", "_test.cpp"])
            ("." : ["../cpplib" | needLibrary])
            ["../cpplib/$(ConfigurationName)" | needLibrary]
            ["cpplib" | needLibrary]
            ["cpplib" | needLibrary]

        generateProjectUnlessExists (croot </> "submission") "submission"
            ["../submission.cpp"]
            ["."]
            []
            []
            []

        generateWorkspace

replace :: Eq a => a -> a -> [a] -> [a]
replace with what = map $ \x -> if x == what then with else x

makeRelative :: F.FilePath -> F.FilePath -> F.FilePath
makeRelative wrt what = decodeString . replace '/' '\\' $
    System.FilePath.makeRelative (encodeString wrt) (encodeString what)

generateProjectUnlessExists :: F.FilePath -> T.Text
                                 -> [T.Text]
                                 -> [T.Text]
                                 -> [T.Text]
                                 -> [T.Text]
                                 -> [String]
                                 -> CaideIO ()
generateProjectUnlessExists projectDir projectName files includePaths libraryPaths libs deps = do
    let projectFile = projectDir </> fromText (T.append projectName ".project")
    projectExists <- liftIO $ isFile projectFile
    if projectExists
    then liftIO . T.putStrLn . T.concat $ [projectName, ".project already exists. Not overwriting"]
    else do
        croot <- caideRoot
        xmlString <- liftIO $ do
            T.putStrLn . T.concat $ ["Generating ", projectName, ".project for Codelite"]
            createDirectory True projectDir
            readTextFile $ croot </> "templates" </> "codelite_project_template.project"

        let doc = parseXML xmlString
            Just cursor = fromForest doc
            transformed = runXmlTransformation
                (generateProjectXML projectName "Executable" files includePaths libraryPaths libs deps)
                cursor

        case transformed of
            Left errorMessage -> throw errorMessage
            Right (_, xml)    -> liftIO . writeTextFile projectFile . T.pack . showXml $ xml

goToProjectTag :: XmlState ()
goToProjectTag = do
    goToDocRoot
    modifyFromJust "Couldn't find CodeLite_Project" $ findRight (isTag "CodeLite_Project")

setProjectName :: T.Text -> XmlState Bool
setProjectName projectName = do
    goToProjectTag
    changeAttr "Name" $ T.unpack projectName

setProjectType :: String -> XmlState Bool
setProjectType projectType = do
    goToProjectTag
    goToChild ["Settings"]
    changed <- changeAttr "Type" projectType
    confChanged <- forEachChild (isTag "Configuration") $ changeAttr "Type" projectType
    return $ or (changed:confChanged)

setOutputFile :: String -> XmlState Bool
setOutputFile outputFile = do
    goToProjectTag
    goToChild ["Settings"]
    changed <- forEachChild (isTag "Configuration") $ do
        goToChild ["General"]
        changed <- changeAttr "OutputFile" outputFile
        modifyFromJust "" parent
        return changed
    return $ or changed

setDependencies :: [String] -> XmlState ()
setDependencies deps = do
    goToProjectTag
    goToChild ["Dependencies"]
    removeChildren $ const True
    forM_ deps $ \dep ->
        insertLastChild $ Elem $ mkElem "Project" [("Name", dep)]

setSourceFiles :: [T.Text] -> XmlState Bool
setSourceFiles sourceFiles = do
    goToProjectTag
    modifyFromJust "Couldn't find VirtualDirectory" $
        findChild $ \c -> isTag "VirtualDirectory" c && hasAttrEqualTo "Name" "src" c
    existingFiles <- (map T.pack . catMaybes) <$>
        forEachChild (isTag "File") (gets (getAttr "Name"))
    let toRemove = existingFiles \\ sourceFiles
        toAdd    = sourceFiles \\ existingFiles
    if null toRemove && null toAdd
    then return False
    else do
        removeChildren $ \c -> isTag "File" c && getAttr "Name" c `elem` map (Just . T.unpack) toRemove
        forM_ toAdd $ \file -> do
            insertLastChild $ Elem $ mkElem "File" [("Name", T.unpack file)]
            modifyFromJust "Already in root" parent
        return True


generateProjectXML :: T.Text -> String -> [T.Text] -> [T.Text] -> [T.Text] -> [T.Text] -> [String] -> XmlState ()
generateProjectXML projectName projectType sourceFiles includePaths libPaths libs deps = do
    _ <- setProjectName projectName
    _ <- setProjectType projectType
    _ <- setSourceFiles sourceFiles

    goToProjectTag
    goToChild ["Settings", "GlobalSettings", "Compiler"]

    forM_ includePaths $ \path -> do
        insertLastChild $ Elem $ mkElem "IncludePath" [("Value", T.unpack path)]
        modifyFromJust "Already in root" parent -- <Compiler>
    modifyFromJust "Already in root" parent -- <GlobalSettings>

    goToChild ["Linker"]
    forM_ libPaths $ \libPath -> do
        insertLastChild $ Elem $ mkElem "LibraryPath" [("Value", T.unpack libPath)]
        modifyFromJust "" parent -- <Linker>
    forM_ libs $ \lib -> do
        insertLastChild $ Elem $ mkElem "Library" [("Value", T.unpack lib)]
        modifyFromJust "" parent -- <Linker>

    setDependencies deps

    goToDocRoot

generateWorkspace :: CaideIO ()
generateWorkspace = do
    croot <- caideRoot
    projects <- getCodeliteProjects
    activeProblem <- getActiveProblem
    let workspaceFile = croot </> "caide.workspace"

    liftIO $ do
        workspaceExists <- isFile workspaceFile
        let existingWorkspace = if workspaceExists
            then workspaceFile
            else croot </> "templates" </> "codelite_workspace_template.workspace"
        xmlString <- readFile $ encodeString existingWorkspace
        let doc = length xmlString `seq` parseXML xmlString
            Just cursor = fromForest doc
            transformed = runXmlTransformation (generateWorkspaceXml projects activeProblem) cursor
        case transformed of
            Left errorMessage -> T.putStrLn . T.concat $ ["Couldn't generate Codelite workspace: ", errorMessage]
            Right (_, xml)    -> writeTextFile workspaceFile . T.pack . showXml $ xml

-- Includes problems and CPP library
getCodeliteProjects :: CaideIO [T.Text]
getCodeliteProjects = do
    croot <- caideRoot
    liftIO $ do
        dirs <- listDirectory croot
        let problemIds = map (pathToText . basename) dirs
            haveCodelite probId = isFile $ croot </> fromText probId </> fromText (T.append probId ".project")
        projectExists <- mapM haveCodelite problemIds
        return $ sort [probId | (probId, True) <- zip problemIds projectExists]


goToWorkspaceTag :: XmlState ()
goToWorkspaceTag = do
    goToDocRoot
    modifyFromJust "Couldn't find Codelite_Workspace" $ findRight (isTag "Codelite_Workspace")


generateWorkspaceXml :: [T.Text] -> T.Text -> XmlState ()
generateWorkspaceXml projects activeProblem = do
    let makeProjectElem projectName = mkElem "Project" (makeAttribs $ T.unpack projectName)
        makeAttribs projectName = [("Name", projectName),("Path", projectName ++ "/" ++ projectName ++ ".project")]
                             ++ [("Active", "Yes") | projectName == T.unpack activeProblem]

    goToWorkspaceTag
    removeChildren (isTag "project")

    goToChild ["BuildMatrix"]
    forM_ projects $ \projectName -> modify (insertLeft $ Elem $ makeProjectElem projectName)

    removeChildren (isTag "WorkspaceConfiguration")
    forM_ ["Debug", "Release"] $ \conf -> do
        insertLastChild $ Elem $ mkElem "WorkspaceConfiguration" [("Name", conf), ("Selected", "yes")]
        forM_ projects $ \projectName -> do
            insertLastChild $ Elem $ mkElem "Project" [("Name", T.unpack projectName), ("ConfigName", conf)]
            modifyFromJust "" parent -- go to WorkspaceConfiguration
        modifyFromJust "" parent -- go to BuildMatrix
    goToDocRoot

