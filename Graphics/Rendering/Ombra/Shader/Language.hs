{-# LANGUAGE FlexibleContexts, RankNTypes, TypeFamilies #-}

module Graphics.Rendering.Ombra.Shader.Language (
        -- * Types
        Shader,
        VertexShader,
        FragmentShader,
        VertexShaderOutput(Vertex),
        FragmentShaderOutput(..),
        ShaderType(zero),
        ShaderVars,
        VOShaderVars,
        Uniform,
        Attribute,
        Generic,
        SVList((:-), N),
        -- ** GPU types
        GenType,
        GenTypeGFloat,
        GMatrix,
        GBool,
        GFloat,
        GInt,
        GSampler2D,
        GSamplerCube,
        GVec2(..),
        GVec3(..),
        GVec4(..),
        GBVec2(..),
        GBVec3(..),
        GBVec4(..),
        GIVec2(..),
        GIVec3(..),
        GIVec4(..),
        GMat2(..),
        GMat3(..),
        GMat4(..),
        GArray,
        -- * Functions
        loop,
        store,
        texture2D,
        texture2DBias,
        texture2DProj,
        texture2DProjBias,
        texture2DProj4,
        texture2DProjBias4,
        texture2DLod,
        texture2DProjLod,
        texture2DProjLod4,
        arrayLength,
        -- ** Math functions
        radians,
        degrees,
        sin,
        cos,
        tan,
        asin,
        acos,
        atan,
        atan2,
        exp,
        log,
        exp2,
        log2,
        sqrt,
        inversesqrt,
        abs,
        absI,
        sign,
        signI,
        floor,
        ceil,
        fract,
        mod,
        min,
        max,
        clamp,
        mix,
        step,
        smoothstep,
        length,
        distance,
        dot,
        cross,
        normalize,
        faceforward,
        reflect,
        refract,
        matrixCompMult,
        -- *** Vector relational functions
        VecOrd,
        VecEq,
        lessThan,
        lessThanEqual,
        greaterThan,
        greaterThanEqual,
        equal,
        notEqual,
        GBoolVector,
        anyBV,
        allBV,
        notBV,
        -- ** Constructors
        true,
        false,
        ToGBool,
        bool,
        ToGInt,
        int,
        ToGFloat,
        float,
        Components,
        CompList,
        ToCompList,
        (#),
        ToGVec2,
        vec2,
        ToGVec3,
        vec3,
        ToGVec4,
        vec4,
        ToGBVec2,
        bvec2,
        ToGBVec3,
        bvec3,
        ToGBVec4,
        bvec4,
        ToGIVec2,
        ivec2,
        ToGIVec3,
        ivec3,
        ToGIVec4,
        ivec4,
        ToGMat2,
        mat2,
        ToGMat3,
        mat3,
        ToGMat4,
        mat4,
        -- ** Operators
        (*),
        (/),
        (+),
        (-),
        (^),
        (&&),
        (||),
        (==),
        (/=),
        (>=),
        (<=),
        (<),
        (>),
        (!),
        not,
        -- ** Rebinding functions
        fromInteger,
        fromRational,
        ifThenElse,
        negate,
        negateI,
        negateM,
        -- ** Prelude functions
        (.),
        id,
        const,
        flip,
        ($),
        CPU.fst,
        CPU.snd,
        -- * Variables
        position,
        fragData,
        fragCoord,
        fragFrontFacing
) where

import GHC.Generics (Generic)
import Graphics.Rendering.Ombra.Shader.CPU
import Graphics.Rendering.Ombra.Shader.Language.Types
import Graphics.Rendering.Ombra.Shader.Language.Functions
import Graphics.Rendering.Ombra.Shader.ShaderVar
import Graphics.Rendering.Ombra.Shader.Stages
import Prelude ((.), id, const, flip, ($))
import qualified Prelude as CPU
