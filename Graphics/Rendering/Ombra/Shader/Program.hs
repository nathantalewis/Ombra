{-# LANGUAGE MultiParamTypeClasses, ExistentialQuantification, ConstraintKinds,
             KindSignatures, DataKinds, GADTs, RankNTypes, FlexibleInstances,
             ScopedTypeVariables, TypeOperators, ImpredicativeTypes,
             TypeSynonymInstances, FlexibleContexts #-}

module Graphics.Rendering.Ombra.Shader.Program (
        LoadedProgram(..),
        Compatible,
        Program,
        ProgramIndex,
        program,
        loadProgram,
        DefaultUniforms2D,
        DefaultAttributes2D,
        DefaultUniforms3D,
        DefaultAttributes3D,
        defaultProgram3D,
        defaultProgram2D,
        programIndex
) where

import Data.Hashable
import qualified Data.HashMap.Strict as H
import qualified Graphics.Rendering.Ombra.Shader.Default2D as Default2D
import qualified Graphics.Rendering.Ombra.Shader.Default3D as Default3D
import Graphics.Rendering.Ombra.Shader.GLSL
import Graphics.Rendering.Ombra.Shader.ShaderVar (ShaderVars)
import Graphics.Rendering.Ombra.Shader.Stages
import Graphics.Rendering.Ombra.Internal.GL hiding (Program)
import qualified Graphics.Rendering.Ombra.Internal.GL as GL
import Graphics.Rendering.Ombra.Internal.Resource
import Graphics.Rendering.Ombra.Internal.TList
import Unsafe.Coerce

-- | A vertex shader associated with a compatible fragment shader.
data Program (gs :: [*]) (is :: [*]) =
        Program (String, [(String, Int)]) String Int

data LoadedProgram = LoadedProgram !GL.Program (H.HashMap String Int) Int

newtype ProgramIndex = ProgramIndex Int deriving Eq

-- | The uniforms used in the default 3D program.
type DefaultUniforms3D = Default3D.Uniforms

-- | The attributes used in the default 3D program.
type DefaultAttributes3D = Default3D.Attributes

-- | The uniforms used in the default 2D program.
type DefaultUniforms2D = Default2D.Uniforms

-- | The attributes used in the default 2D program.
type DefaultAttributes2D = Default2D.Attributes

instance Hashable (Program gs is) where
        hashWithSalt salt (Program _ _ h) = hashWithSalt salt h

instance Eq (Program gs is) where
        (Program _ _ h) == (Program _ _ h') = h == h'

instance Hashable LoadedProgram where
        hashWithSalt salt (LoadedProgram _ _ h) = hashWithSalt salt h

instance Eq LoadedProgram where
        (LoadedProgram _ _ h) == (LoadedProgram _ _ h') = h == h'

instance GLES => Resource (Program g i) LoadedProgram GL where
        -- TODO: err check!
        loadResource i = Right <$> loadProgram i
        unloadResource _ (LoadedProgram p _ _) = deleteProgram p

-- | Compatible shaders.
type Compatible pgs vgs fgs =
        EqualOrErr pgs (Union vgs fgs)
                   (Text "Incompatible shader uniforms" :$$:
                    Text "    Vertex shader uniforms: " :<>:
                    ShowType vgs :$$:
                    Text "    Fragment shader uniforms: " :<>:
                    ShowType fgs :$$:
                    Text "    United shader uniforms: " :<>:
                    ShowType (Union vgs fgs) :$$:
                    Text "    Program uniforms: " :<>:
                    ShowType pgs)

-- | Create a 'Program' from the shaders.
program :: ( ShaderVars vgs, ShaderVars vis, VOShaderVars os , ShaderVars fgs
           , Compatible pgs vgs fgs )
        => VertexShader vgs vis os -> FragmentShader fgs os
        -> Program pgs vis
program vs fs = let (vss, attrs) = vertexToGLSLAttr vs
                    fss = fragmentToGLSL fs
                in Program (vss, attrs) fss (hash (vss, fss))

programIndex :: Program gs is -> ProgramIndex
programIndex (Program _ _ h) = ProgramIndex h

defaultProgram3D :: Program DefaultUniforms3D DefaultAttributes3D
defaultProgram3D = program Default3D.vertexShader Default3D.fragmentShader

defaultProgram2D :: Program DefaultUniforms2D DefaultAttributes2D
defaultProgram2D = program Default2D.vertexShader Default2D.fragmentShader

loadProgram :: GLES => Program g i -> GL LoadedProgram
loadProgram (Program (vss, attrs) fss h) =
        do glp <- createProgram
  
           vs <- loadSource gl_VERTEX_SHADER vss
           fs <- loadSource gl_FRAGMENT_SHADER fss
           attachShader glp vs
           attachShader glp fs
  
           locs <- bindAttribs glp 0 attrs []
           linkProgram glp
  
           -- TODO: ??
           {-
           detachShader glp vs
           detachShader glp fs
           -}
  
           return $ LoadedProgram glp (H.fromList locs) h

        where bindAttribs _ _ [] r = return r
              bindAttribs glp i ((nm, sz) : xs) r =
                        bindAttribLocation glp (fromIntegral i) (toGLString nm)
                        >> bindAttribs glp (i + sz) xs ((nm, i) : r)

loadSource :: GLES => GLEnum -> String -> GL Shader
loadSource ty src =
        do shader <- createShader ty
           shaderSource shader $ toGLString src
           compileShader shader
           return shader
