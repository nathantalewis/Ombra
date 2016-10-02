{-# LANGUAGE GADTs, DataKinds, FlexibleContexts, TypeSynonymInstances,
             FlexibleInstances, MultiParamTypeClasses, KindSignatures #-}

module Graphics.Rendering.Ombra.Draw.Internal (
        Draw,
        DrawState,
        drawState,
        drawInit,
        clearBuffers,
        drawLayer,
        drawGroup,
        drawObject,
        removeGeometry,
        removeTexture,
        removeProgram,
        textureUniform,
        textureSize,
        setProgram,
        resizeViewport,
        runDraw,
        execDraw,
        evalDraw,
        gl,
        renderLayer,
        layerToTexture,
        drawGet
) where

import qualified Graphics.Rendering.Ombra.Blend as Blend
import Graphics.Rendering.Ombra.Geometry
import Graphics.Rendering.Ombra.Color
import Graphics.Rendering.Ombra.Shapes
import Graphics.Rendering.Ombra.Types
import Graphics.Rendering.Ombra.Texture
import Graphics.Rendering.Ombra.Backend (GLES)
import qualified Graphics.Rendering.Ombra.Backend as GL
import Graphics.Rendering.Ombra.Internal.GL hiding (Texture, Program, Buffer,
                                                    UniformLocation, cullFace,
                                                    depthMask)
import qualified Graphics.Rendering.Ombra.Internal.GL as GL
import Graphics.Rendering.Ombra.Internal.Resource
import Graphics.Rendering.Ombra.Shader.CPU
import Graphics.Rendering.Ombra.Shader.GLSL
import Graphics.Rendering.Ombra.Shader.Program
import Graphics.Rendering.Ombra.Shader.ShaderVar
import qualified Graphics.Rendering.Ombra.Stencil as Stencil

import Data.Bits ((.|.))
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as H
import qualified Data.Vector as V
import Data.Typeable
import Data.Vect.Float
import Data.Word (Word, Word8)
import Control.Applicative
import Control.Monad (when)
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.State

-- | Create a 'DrawState'.
drawState :: GLES
          => Int         -- ^ Viewport width
          -> Int         -- ^ Viewport height
          -> IO DrawState
drawState w h = do programs <- newGLResMap
                   gpuBuffers <- newGLResMap
                   gpuVAOs <- newDrawResMap
                   uniforms <- newGLResMap
                   textureImages <- newGLResMap
                   return DrawState { currentProgram = Nothing
                                    , loadedProgram = Nothing
                                    , programs = programs
                                    , gpuBuffers = gpuBuffers
                                    , gpuVAOs = gpuVAOs
                                    , uniforms = uniforms
                                    , textureImages = textureImages
                                    , activeTextures =
                                            V.replicate maxTexs Nothing
                                    , viewportSize = (w, h)
                                    , blendMode = Nothing
                                    , depthTest = True
                                    , depthMask = True
                                    , stencilMode = Nothing
                                    , cullFace = Just CullBack
                                    }

        where newGLResMap :: (Hashable i, Resource i r GL) => IO (ResMap i r)
              newGLResMap = newResMap
              
              newDrawResMap :: (Hashable i, Resource i r Draw)
                            => IO (ResMap i r)
              newDrawResMap = newResMap

drawInit :: GLES => Draw ()
drawInit = viewportSize <$> Draw get >>=
           \(w, h) -> gl $ do clearColor 0.0 0.0 0.0 1.0
                              enable gl_DEPTH_TEST
                              depthFunc gl_LESS
                              viewport 0 0 (fromIntegral w) (fromIntegral h)


maxTexs :: (Integral a, GLES) => a
maxTexs = 32 -- fromIntegral gl_MAX_COMBINED_TEXTURE_IMAGE_UNITS -- XXX

-- | Run a 'Draw' action.
runDraw :: Draw a
        -> DrawState
        -> GL (a, DrawState)
runDraw (Draw a) = runStateT a

-- | Execute a 'Draw' action.
execDraw :: Draw a              -- ^ Action.
         -> DrawState           -- ^ State.
         -> GL DrawState
execDraw (Draw a) = execStateT a

-- | Evaluate a 'Draw' action.
evalDraw :: Draw a              -- ^ Action.
         -> DrawState           -- ^ State.
         -> GL a
evalDraw (Draw a) = evalStateT a

-- | Viewport.
resizeViewport :: GLES
               => Int   -- ^ Width.
               -> Int   -- ^ Height.
               -> Draw ()
resizeViewport w h = do gl $ viewport 0 0 (fromIntegral w) (fromIntegral h)
                        Draw . modify $ \s -> s { viewportSize = (w, h) }

clearBuffers :: GLES => [Buffer] -> Draw ()
clearBuffers = mapM_ $ gl . clear . buffer
        where buffer ColorBuffer = gl_COLOR_BUFFER_BIT
              buffer DepthBuffer = gl_DEPTH_BUFFER_BIT
              buffer StencilBuffer = gl_STENCIL_BUFFER_BIT

-- | Manually delete a 'Geometry' from the GPU (this is automatically done when
-- the 'Geometry' becomes unreachable). Note that if you try to draw it, it will
-- be allocated again.
removeGeometry :: GLES => Geometry is -> Draw ()
removeGeometry gi = let g = castGeometry gi in
        do removeDrawResource gl gpuBuffers g
           removeDrawResource id gpuVAOs g

-- | Manually delete a 'Texture' from the GPU.
removeTexture :: GLES => Texture -> Draw ()
removeTexture (TextureImage i) = removeDrawResource gl textureImages i
removeTexture (TextureLoaded l) = gl $ unloadResource
                                        (Nothing :: Maybe TextureImage) l

-- | Manually delete a 'Program' from the GPU.
removeProgram :: GLES => Program gs is -> Draw ()
removeProgram = removeDrawResource gl programs . castProgram

-- | Draw a 'Layer'.
drawLayer :: GLES => Layer -> Draw ()
-- TODO: freeActiveTextures should not be here
drawLayer (Layer prg grp) = freeActiveTextures >>
                            setProgram prg >>
                            drawGroup grp
drawLayer (SubLayer rl) =
        do (layer, textures) <- renderLayer rl
           drawLayer layer
           mapM_ removeTexture textures
drawLayer (OverLayer top behind) = drawLayer behind >> drawLayer top
drawLayer (ClearLayer bufs l) = clearBuffers bufs >> drawLayer l

-- | Draw a 'Group'.
drawGroup :: GLES => Group gs is -> Draw ()
drawGroup Empty = return ()
drawGroup (Object o) = drawObject o
drawGroup (Global (g := c) o) = c >>= uniform single (g undefined)
                                  >>  drawGroup o
drawGroup (Append g g') = drawGroup g >> drawGroup g'
drawGroup (Blend m g) = stateReset blendMode setBlendMode m $ drawGroup g
drawGroup (Stencil m g) = stateReset stencilMode setStencilMode m $ drawGroup g
drawGroup (DepthTest d g) = stateReset depthTest setDepthTest d $ drawGroup g
drawGroup (DepthMask d g) = stateReset depthMask setDepthMask d $ drawGroup g
drawGroup (Cull face g) = stateReset cullFace setCullFace face $ drawGroup g

stateReset :: (DrawState -> a) -> (a -> Draw ()) -> a -> Draw () -> Draw ()
stateReset getOld set new act = do old <- getOld <$> Draw get
                                   set new
                                   act
                                   set old

-- | Draw an 'Object'.
drawObject :: GLES => Object gs is -> Draw ()
drawObject NoMesh = return ()
drawObject (Mesh g) = withRes_ (getGPUVAOGeometry $ castGeometry g)
                                 drawGPUVAOGeometry
drawObject ((g := c) :~> o) = c >>= uniform single (g undefined) >> drawObject o

uniform :: (GLES, ShaderVar g, Uniform s g)
        => proxy (s :: CPUSetterType *) -> g -> CPU s g -> Draw ()
uniform p g c = withUniforms p g c $
                        \n ug uc -> withRes_ (getUniform $ uniformName g n) $
                                \(UniformLocation l) -> gl $ setUniform l ug uc
                                                                

-- | This helps you set the uniforms of type 'Graphics.Rendering.Ombra.Shader.Sampler2D'.
textureUniform :: GLES  => Texture -> Draw ActiveTexture
textureUniform tex = withRes (getTexture tex) (return $ ActiveTexture 0)
                                 $ \(LoadedTexture _ _ wtex) ->
                                        do at <- makeActive tex
                                           gl $ bindTexture gl_TEXTURE_2D wtex
                                           return at

-- | Get the dimensions of a 'Texture'.
textureSize :: (GLES, Num a) => Texture -> Draw (a, a)
textureSize tex = withRes (getTexture tex) (return (0, 0))
                          $ \(LoadedTexture w h _) -> return ( fromIntegral w
                                                             , fromIntegral h)

-- | Set the program.
setProgram :: GLES => Program g i -> Draw ()
setProgram p = do current <- currentProgram <$> Draw get
                  when (current /= Just (castProgram p)) $
                        withRes_ (getProgram $ castProgram p) $
                                \lp@(LoadedProgram glp _ _) -> do
                                   Draw . modify $ \s -> s {
                                           currentProgram = Just $ castProgram p,
                                           loadedProgram = Just lp
                                   }
                                   gl $ useProgram glp

withRes_ :: Draw (Either String a) -> (a -> Draw ()) -> Draw ()
withRes_ drs = withRes drs $ return ()

withRes :: Draw (Either String a) -> Draw b -> (a -> Draw b) -> Draw b
withRes drs u l = drs >>= \rs -> case rs of
                                      Right r -> l r
                                      _ -> u

getUniform :: GLES => String -> Draw (Either String UniformLocation)
getUniform name = do mprg <- loadedProgram <$> Draw get
                     case mprg of
                          Just prg -> getDrawResource gl uniforms (prg, name)
                          Nothing -> return $ Left "No loaded program."

getGPUVAOGeometry :: GLES => Geometry '[] -> Draw (Either String GPUVAOGeometry)
getGPUVAOGeometry = getDrawResource id gpuVAOs

getGPUBufferGeometry :: GLES => Geometry '[]
                     -> Draw (Either String GPUBufferGeometry)
getGPUBufferGeometry = getDrawResource gl gpuBuffers

getTexture :: GLES => Texture -> Draw (Either String LoadedTexture)
getTexture (TextureLoaded l) = return $ Right l
getTexture (TextureImage t) = getTextureImage t

getTextureImage :: GLES => TextureImage
                -> Draw (Either String LoadedTexture)
getTextureImage = getDrawResource gl textureImages

getProgram :: GLES
           => Program '[] '[] -> Draw (Either String LoadedProgram)
getProgram = getDrawResource gl programs

freeActiveTextures :: GLES => Draw ()
freeActiveTextures = Draw . modify $ \ds ->
        ds { activeTextures = V.replicate maxTexs Nothing }

-- XXX: inefficient
makeActive :: GLES => Texture -> Draw ActiveTexture
makeActive t = do ats <- activeTextures <$> Draw get
                  let at@(ActiveTexture atn) =
                        case V.elemIndex (Just t) ats of
                                Just n -> ActiveTexture $ fi n
                                Nothing ->
                                        case V.elemIndex Nothing ats of
                                             Just n -> ActiveTexture $ fi n
                                             -- TODO: Draw () error reporting
                                             Nothing -> ActiveTexture 0
                  gl . activeTexture $ gl_TEXTURE0 + fi atn
                  Draw . modify $ \ds ->
                          ds { activeTextures = ats V.// [(fi atn, Just t)] }
                  return at
        where fi :: (Integral a, Integral b) => a -> b
              fi = fromIntegral


-- | Realize a 'RenderLayer'. It returns the list of allocated 'Texture's so
-- that you can free them if you want.
renderLayer :: GLES => RenderLayer a -> Draw (a, [Texture])
renderLayer (RenderLayer drawBufs stypes w' h' rx ry rw rh
                         inspCol inspDepth layer f) =
        do (ts, mcol, mdepth) <- layerToTexture drawBufs stypes w h layer
                                                (mayInspect inspCol)
                                                (mayInspect inspDepth)
           return (f ts mcol mdepth, ts)
        where w = fromIntegral w'
              h = fromIntegral h'

              mayInspect :: Bool
                         -> Either (Maybe [r])
                                   ([r] -> Draw (Maybe [r]), Int, Int, Int, Int)
              mayInspect True = Right (return . Just, rx, ry, rw, rh)
              mayInspect False = Left Nothing

-- | Draw a 'Layer' on some textures.
layerToTexture :: (GLES, Integral a)
               => Bool                                  -- ^ Draw buffers
               -> [LayerType]                           -- ^ Textures contents
               -> a                                     -- ^ Width
               -> a                                     -- ^ Height
               -> Layer                                 -- ^ Layer to draw
               -> Either b ( [Color] -> Draw b
                           , Int, Int, Int, Int)        -- ^ Color inspecting
                                                        -- function, start x,
                                                        -- start y, width,
                                                        -- height
               -> Either c ( [Word8] -> Draw c
                           , Int, Int, Int, Int)        -- ^ Depth inspecting,
                                                        -- function, etc.
               -> Draw ([Texture], b ,c)
layerToTexture drawBufs stypes wp hp layer einspc einspd = do
        (ts, (colRes, depthRes)) <- renderToTexture drawBufs (map arguments
                                                    stypes) w h $
                        do drawLayer layer
                           colRes <- inspect einspc gl_RGBA wordsToColors 4
                           depthRes <- inspect einspd gl_DEPTH_COMPONENT id 1
                           return (colRes, depthRes)

        return (map (TextureLoaded . LoadedTexture w h) ts, colRes, depthRes)

        where (w, h) = (fromIntegral wp, fromIntegral hp)
              arguments stype =
                        case stype of
                              ColorLayer -> ( fromIntegral gl_RGBA
                                            , gl_RGBA
                                            , gl_UNSIGNED_BYTE
                                            , gl_COLOR_ATTACHMENT0
                                            , [ColorBuffer] )
                              DepthLayer -> ( fromIntegral gl_DEPTH_COMPONENT
                                            , gl_DEPTH_COMPONENT
                                            , gl_UNSIGNED_SHORT
                                            , gl_DEPTH_ATTACHMENT
                                            , [DepthBuffer] )
                              DepthStencilLayer -> ( fromIntegral
                                                        gl_DEPTH_STENCIL
                                                   , gl_DEPTH_STENCIL
                                                   , gl_UNSIGNED_INT_24_8
                                                   , gl_DEPTH_STENCIL_ATTACHMENT
                                                   , [ DepthBuffer
                                                     , StencilBuffer]
                                                   )
                              BufferLayer n -> ( fromIntegral gl_RGBA32F
                                               , gl_RGBA
                                               , gl_FLOAT
                                               , gl_COLOR_ATTACHMENT0 + 
                                                 fromIntegral n
                                               , [] )

              inspect :: Either c (a -> Draw c, Int, Int, Int, Int) -> GLEnum
                      -> ([Word8] -> a) -> Int -> Draw c
              inspect (Left r) _ _ s = return r
              inspect (Right (insp, x, y, rw, rh)) format trans s =
                        do arr <- liftIO . newByteArray $
                                        fromIntegral rw * fromIntegral rh * s
                           gl $ readPixels (fromIntegral x)
                                           (fromIntegral y)
                                           (fromIntegral rw)
                                           (fromIntegral rh)
                                           format gl_UNSIGNED_BYTE arr
                           liftIO (decodeBytes arr) >>= insp . trans
              wordsToColors (r : g : b : a : xs) = Color r g b a :
                                                   wordsToColors xs
              wordsToColors _ = []

renderToTexture :: GLES
                => Bool -> [(GLInt, GLEnum, GLEnum, GLEnum, [Buffer])]
                -> GLSize -> GLSize -> Draw a -> Draw ([GL.Texture], a)
renderToTexture drawBufs infos w h act = do
        fb <- gl createFramebuffer 
        gl $ bindFramebuffer gl_FRAMEBUFFER fb

        (ts, attchs, buffersToClear) <- fmap unzip3 . gl . flip mapM infos $
                \(internalFormat, format, pixelType, attachment, buffer) ->
                        do t <- emptyTexture
                           arr <- liftIO $ noUInt8Array
                           bindTexture gl_TEXTURE_2D t
                           texImage2D gl_TEXTURE_2D 0 internalFormat w 
                                      h 0 format pixelType arr
                           framebufferTexture2D gl_FRAMEBUFFER attachment
                                                gl_TEXTURE_2D t 0
                           return (t, fromIntegral attachment, buffer)

        let buffersToDraw = filter (/= fromIntegral gl_DEPTH_ATTACHMENT) attchs
        when drawBufs $ liftIO (encodeInts buffersToDraw) >>= gl . drawBuffers

        (sw, sh) <- viewportSize <$> Draw get
        resizeViewport (fromIntegral w) (fromIntegral h)

        clearBuffers $ concat buffersToClear
        ret <- act

        resizeViewport sw sh
        gl $ deleteFramebuffer fb

        return (ts, ret)

setBlendMode :: GLES => Maybe Blend.Mode -> Draw ()
setBlendMode Nothing = do m <- blendMode <$> Draw get
                          case m of
                               Just _ -> gl $ disable gl_BLEND
                               Nothing -> return ()
                          Draw . modify $ \s -> s { blendMode = Nothing }
setBlendMode (Just newMode) =
        do mOldMode <- blendMode <$> Draw get
           case mOldMode of
                Nothing -> do gl $ enable gl_BLEND
                              changeColor >> changeEquation >> changeFunction
                Just oldMode ->
                     do when (Blend.constantColor oldMode /= constantColor)
                                changeColor
                        when (Blend.equation oldMode /= equation)
                                changeEquation
                        when (Blend.function oldMode /= function)
                                changeFunction
           Draw . modify $ \s -> s { blendMode = Just newMode }
        where constantColor = Blend.constantColor newMode
              equation@(rgbEq, alphaEq) = Blend.equation newMode
              function@(rgbs, rgbd, alphas, alphad) = Blend.function newMode
              changeColor = case constantColor of
                                 Just (Vec4 r g b a) -> gl $ blendColor r g b a
                                 Nothing -> return ()
              changeEquation = gl $ blendEquationSeparate rgbEq alphaEq
              changeFunction = gl $ blendFuncSeparate rgbs rgbd
                                                      alphas alphad

setStencilMode :: GLES => Maybe Stencil.Mode -> Draw ()
setStencilMode Nothing = do m <- stencilMode <$> Draw get
                            case m of
                                 Just _ -> gl $ disable gl_STENCIL_TEST
                                 Nothing -> return ()
                            Draw . modify $ \s -> s { stencilMode = Nothing }
setStencilMode (Just newMode@(Stencil.Mode newFun newOp)) =
        do mOldMode <- stencilMode <$> Draw get
           case mOldMode of
                Nothing -> do gl $ enable gl_STENCIL_TEST
                              sides newFun changeFunction
                              sides newOp changeOperation
                Just (Stencil.Mode oldFun oldOp) ->
                        do when (oldFun /= newFun) $
                                sides newFun changeFunction
                           when (oldOp /= newOp) $
                                sides newOp changeOperation
           Draw . modify $ \s -> s { stencilMode = Just newMode }
        where changeFunction face f = let (t, v, m) = Stencil.function f
                                      in gl $ stencilFuncSeparate face t v m
              changeOperation face o = let (s, d, n) = Stencil.operation o
                                       in gl $ stencilOpSeparate face s d n
              sides (Stencil.FrontBack x) f = f gl_FRONT_AND_BACK x
              sides (Stencil.Separate x y) f = f gl_FRONT x >> f gl_BACK y

setCullFace :: GLES => Maybe CullFace -> Draw ()
setCullFace Nothing = do old <- cullFace <$> Draw get
                         case old of
                              Just _ -> gl $ disable gl_CULL_FACE
                              Nothing -> return ()
                         Draw . modify $ \s -> s { cullFace = Nothing }
setCullFace (Just newFace) =
        do old <- cullFace <$> Draw get
           when (old == Nothing) . gl $ enable gl_CULL_FACE
           case old of
                Just oldFace | oldFace == newFace -> return ()
                _ -> gl . GL.cullFace $ case newFace of
                                             CullFront -> gl_FRONT
                                             CullBack -> gl_BACK
                                             CullFrontBack -> gl_FRONT_AND_BACK
           Draw . modify $ \s -> s { cullFace = Just newFace }
                   
setDepthTest :: GLES => Bool -> Draw ()
setDepthTest = setFlag depthTest (\x s -> s { depthTest = x })
                       (gl $ enable gl_DEPTH_TEST) (gl $ disable gl_DEPTH_TEST)
                   
setDepthMask :: GLES => Bool -> Draw ()
setDepthMask = setFlag depthMask (\x s -> s { depthMask = x })
                       (gl $ GL.depthMask true) (gl $ GL.depthMask false)

setFlag :: GLES
        => (DrawState -> Bool)
        -> (Bool -> DrawState -> DrawState)
        -> Draw ()
        -> Draw ()
        -> Bool
        -> Draw ()
setFlag getFlag setFlag enable disable new =
        do old <- getFlag <$> Draw get
           case (old, new) of
                   (False, True) -> enable
                   (True, False) -> disable
                   _ -> return ()
           Draw . modify $ setFlag new

getDrawResource :: (Resource i r m, Hashable i)
                => (m (Either String r) -> Draw (Either String r))
                -> (DrawState -> ResMap i r)
                -> i
                -> Draw (Either String r)
getDrawResource lft mg i = do
        map <- mg <$> Draw get
        lft $ getResource i map

removeDrawResource :: (Resource i r m, Hashable i)
                   => (m () -> Draw ())
                   -> (DrawState -> ResMap i r)
                   -> i
                   -> Draw ()
removeDrawResource lft mg i = do
        s <- mg <$> Draw get
        lft $ removeResource i s

drawGPUVAOGeometry :: GLES => GPUVAOGeometry -> Draw ()
drawGPUVAOGeometry (GPUVAOGeometry _ ec vao) = currentProgram <$> Draw get >>=
        \mcp -> case mcp of
                     Just _ -> gl $ do bindVertexArray vao
                                       drawElements gl_TRIANGLES
                                                    (fromIntegral ec)
                                                    gl_UNSIGNED_SHORT
                                                    nullGLPtr
                                       bindVertexArray noVAO
                     Nothing -> return ()

instance GLES => Resource (LoadedProgram, String) UniformLocation GL where
        loadResource (LoadedProgram prg _ _, g) =
                do loc <- getUniformLocation prg $ toGLString g
                   return . Right $ UniformLocation loc
        unloadResource _ _ = return ()

instance GLES => Resource (Geometry '[]) GPUVAOGeometry Draw where
        loadResource g =
                do ge <- getGPUBufferGeometry g
                   case ge of
                        Left err -> return $ Left err
                        Right buf -> gl $ loadResource buf

        unloadResource _ =
                gl . unloadResource (Nothing :: Maybe GPUBufferGeometry)

-- | Perform a 'GL' action in the 'Draw' monad.
gl :: GL a -> Draw a
gl = Draw . lift

-- | Get the 'DrawState'.
drawGet :: Draw DrawState
drawGet = Draw get
