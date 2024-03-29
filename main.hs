import Codec.Picture.Types
import Codec.Picture.Saving
import Data.List
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import System.IO
import Data.Array

data Vec = Vec { xval :: Float, yval :: Float, zval :: Float } deriving (Eq, Show)

instance Num Vec where
    (Vec a1 b1 c1) + (Vec a2 b2 c2) = Vec (a1 + a2) (b1 + b2) (c1 + c2)
    (Vec a1 b1 c1) - (Vec a2 b2 c2) = Vec (a1 - a2) (b1 - b2) (c1 - c2)
    negate (Vec a b c) = Vec (-a) (-b) (-c)
    (Vec a1 b1 c1) * (Vec a2 b2 c2) = Vec (b1 * c2 - c1 * b2) (c1 * a2 - a1 * c2) (a1 * b2 - b1 * a2) -- Cross product
    abs = undefined
    signum = undefined
    fromInteger n = (Vec nf nf nf) where nf = fromInteger n
 
dot :: Vec -> Vec -> Float
dot (Vec a1 b1 c1) (Vec a2 b2 c2) = (a1 * a2) + (b1 * b2) + (c1 * c2)

scalarMult :: Float -> Vec -> Vec
scalarMult alpha (Vec a b c) = Vec (alpha * a) (alpha * b) (alpha * c)

norm :: Vec -> Float
norm a = sqrt $ dot a a

normalize :: Vec -> Vec
normalize (Vec a b c) = Vec (a / n) (b / n) (c / n) where n = norm (Vec a b c)

-- sqrt not necessary for comparisons
distSqr :: Vec -> Vec -> Float
distSqr a b = norm $ a - b

dist :: Vec -> Vec -> Float
dist a b = sqrt $ dist a b

-- I didn't make this signum because i can't guarantee (abs a) * (signum a) = a
-- which is a requirement of those functions
signs :: Vec -> Vec
signs (Vec a b c) = Vec (signum a) (signum b) (signum c)

data Material = Material { matColor :: Color, matPower :: Float, matDiffuse :: Float, matSpecular :: Float, matReflectivity :: Float } deriving (Eq, Show)
data Sphere = Sphere { sphereOrigin :: Vec, sphereRadius :: Float } deriving (Eq, Show)

data Ray = Ray { rayOrigin :: Vec, rayDirection :: Vec } deriving (Eq, Show) -- Note: Direction is normalized

class Geometry a where
    intersectsRay :: a -> Ray -> Maybe [Vec]
    normalAtPoint :: a -> Vec -> Maybe Ray -- Can't get a normal on corners

instance Geometry Sphere where
    intersectsRay (Sphere c r) (Ray o l) = 
        if disc < 0 then
            Nothing
        else
            let d1 = -(dot l (o - c)) + (sqrt disc)
                d2 = -(dot l (o - c)) - (sqrt disc) in
            if d1 <= 0 && d2 > 0 then Just [o + (scalarMult d2 l)]
            else if d1 > 0 && d2 <= 0 then Just [o + (scalarMult d1 l)]
            else if d1 <= 0 && d2 <= 0 then Nothing
            else Just [o + (scalarMult d1 l), o + (scalarMult d2 l)]                
        where disc = (dot l (o - c))^2 - (norm $ o - c)^2 + r^2
    normalAtPoint (Sphere c r) point = Just $ Ray origin direction
        where origin = point
              direction = normalize $ point - c

type Color = Vec -- So I can do scalar multiplication and addition, which AFAIK PixelRGBF cannot.
type Light = Vec -- Assuming full intensity, white light, for now.
type Scene = [(Ray -> Maybe [Vec], Vec -> Maybe Ray, Material)]

fstOfThree :: (a, b, c) -> a
fstOfThree (a, b, c) = a

sndOfThree :: (a, b, c) -> b
sndOfThree (a, b, c) = b

thdOfThree :: (a, b, c) -> c
thdOfThree (a, b, c) = c

findIntersections :: Scene -> Ray -> [Maybe [Vec]]
findIntersections scene r = map ($ r) ir
    where ir = map fstOfThree scene

-- Helper
justOrZero :: Num t => Maybe t -> t
justOrZero r = case r of Nothing -> 0
                         Just a -> a

pointOfIntersection :: Ray -> Maybe [Vec] -> Vec
pointOfIntersection r Nothing = (1/0) `scalarMult` rayDirection r
pointOfIntersection r (Just vecs) = 
    let d = map (distSqr $ rayOrigin r) vecs
        m = minimum d
        minElem = justOrZero (elemIndex m d) in
            vecs !! minElem

distToIntersectionSqr :: Ray -> Maybe [Vec] -> Float
distToIntersectionSqr r int = case int of Nothing -> infinity
                                          Just vecs -> let d = map (distSqr $ rayOrigin r) vecs
                                                           m = minimum d in
                                                              d !! (justOrZero $ elemIndex m d)
    where infinity = 1/0

closestIntersection :: Scene -> Ray -> Maybe (Vec, Vec -> Maybe Ray, Material) -- a little awkward
closestIntersection scene r =
     if minIntersectionDist == (1/0) then Nothing
     else case minIntersectionIndex of  Nothing -> Nothing
                                        Just index -> 
                                            Just (pointOfIntersection r (intersections !! index),
                                                  sndOfThree (scene !! index), thdOfThree (scene !! index))
    where intersections = findIntersections scene r
          closestIntersectionDists = map (distToIntersectionSqr r) intersections
          minIntersectionDist = minimum closestIntersectionDists
          minIntersectionIndex = elemIndex minIntersectionDist closestIntersectionDists

pointIsInShadow :: Vec -> Scene -> [Light] -> Bool
pointIsInShadow point scene (x:xs) =
    case closest of Nothing -> pointIsInShadow point scene xs
                    _ -> True
    where lightRayDir = (normalize $ x - point)
          epsilon = 0.001 -- My favorite small number
          lightRay = Ray (point + (scalarMult epsilon lightRayDir)) lightRayDir
          closest = closestIntersection scene lightRay

pointIsInShadow _ _ [] = False

reflectRay :: Ray -> Ray -> Ray
reflectRay (Ray incPos incDir) (Ray normPos normDir) = Ray (incPos + (scalarMult epsilon reflDir)) reflDir
    where reflDir = (scalarMult (-2 * (dot incDir normDir)) normDir) + incDir
          epsilon = 0.001

shade :: Scene -> Ray -> Maybe Ray -> Material -> [Light] -> Int -> Color
shade scene ray normal mat lights reflectionTreeDepth =
    case normal of Just normRay -> let diff = (matDiffuse mat) `scalarMult` (diffuse normRay mat lights)
                                       spec = (matSpecular mat) `scalarMult` (specular ray normRay mat lights)
                                       shadow = pointIsInShadow (rayOrigin normRay) scene lights
                                       reflection = traceRay scene (reflectRay ray normRay) lights (reflectionTreeDepth - 1)
                                       reflColor = scalarMult (matReflectivity mat) reflection in
                                       if matReflectivity mat == 0 || reflectionTreeDepth == 0 then
                                           if shadow == True then
                                               ambient
                                           else
                                               ambient + diff + spec
                                       else
                                           if shadow == True then
                                               ambient + reflColor
                                           else
                                               ambient + diff + spec + reflColor
                   Nothing -> ambient -- I'm going to punt on edges for now. On polyhedra, can probably just pick any normal for edges? Investigate
    where ambient = 0.1 `scalarMult` matColor mat

diffuse :: Ray -> Material -> [Light] -> Color
diffuse (Ray normOri normDir) (Material mc _ _ _ _) lights = sum colors
    where lightDirs = map (\x -> normalize $ x - normOri) lights
          lamberts = map (\x -> max (dot normDir x) 0) lightDirs -- if dot is negative, light is behind face.
          colors = map (\x -> scalarMult x mc) lamberts

-- Blinn-Torrance model
specular :: Ray -> Ray -> Material -> [Light] -> Color
specular (Ray viewOri viewDir) (Ray normOri normDir) (Material _ power _ _ _) lights = sum colors
    where backwardViewDir = scalarMult (-1) viewDir
          lightDirs = map (\x -> normalize $ x - normOri) lights
          bisections = map (\x -> normalize (x + backwardViewDir)) lightDirs
          angles = map (dot normDir) bisections
          falloffs = map (\x -> x ** power) angles
          colors = map (\x -> scalarMult x (Vec 1 1 1)) falloffs -- Again, assuming white light for now and full material power

data Camera = Camera { camPos :: Vec, camLookDir :: Vec, camUpDir :: Vec, camPlaneDist :: Float }

-- Sets up image plane and generates rays
castRays :: Camera -> Float -> Float -> Int -> Int -> Float -> [Ray]
castRays (Camera pos look v dist) width height xPixels yPixels pixelDensity = map (\corner -> Ray pos (normalize $ corner - pos)) pixelCorners
    where n = -1 `scalarMult` (normalize $ look) -- Camera normal
          u = normalize $ v * n -- Camera right
          viewportCenter = (dist `scalarMult` look) + pos
          pairs = [(fromIntegral x, fromIntegral y) | x <- [0  .. (xPixels - 1)], y <- [0 .. (yPixels - 1)]]
          upperLeft = viewportCenter - (width / 2) `scalarMult` u + (height / 2) `scalarMult` v
          pixelCorners = map (\(x, y) -> upperLeft +  (x * (width / (fromIntegral xPixels))) `scalarMult` u 
                            - (y * (height / (fromIntegral yPixels))) `scalarMult` v) pairs  

vec2pix :: Vec -> PixelRGBF
vec2pix (Vec a b c) = PixelRGBF a b c

traceRay :: Scene -> Ray -> [Light] -> Int -> Color
traceRay scene ray lights reflectionTreeDepth =
    case closest of Just (vec, normFunc, mat) -> shade scene ray (normFunc vec) mat lights reflectionTreeDepth
                    Nothing -> Vec 0 0 0
    where closest = closestIntersection scene ray
   
main = do
    B.writeFile "out.png" $ BL.toStrict $ imageToPng img
    where cam = Camera (Vec 0 0 (-1)) (Vec 0 0 1) (Vec 0 1 0) 1
          planeWidth = 3.0
          planeHeight = 3.0
          pixelDensity = 100000.0
          pixelWidth = floor $ (sqrt pixelDensity) * planeWidth
          pixelHeight = floor $ (sqrt pixelDensity) * planeHeight
          sphere1 = Sphere (Vec 0 1 (-3)) 1
          sphere2 = Sphere (Vec (0) 2 6) 4
          sphere3 = Sphere (Vec (-1) 0 (-3)) 1
          sphere4 = Sphere (Vec (1) 0 (-3)) 1 
          sphere5 = Sphere (Vec 0 (-401) 2) 400
          scene = [(intersectsRay sphere1, normalAtPoint sphere1, (Material (Vec (135/255) (67/255) (232/255)) 10 1 1 0)),
                   (intersectsRay sphere2, normalAtPoint sphere2, (Material (Vec (255/255) (255/255) (255/255)) 50 1 1 1)),
                   (intersectsRay sphere3, normalAtPoint sphere3, (Material (Vec (255/255) (0/255) (0/255)) 10 1 1 0)),
                   (intersectsRay sphere4, normalAtPoint sphere4, (Material (Vec (0/255) (255/255) (0/255)) 10 1 1 0)),
                   (intersectsRay sphere5, normalAtPoint sphere5, (Material (Vec (13/255) (181/255) (255/255)) 10 1 1 0))]
          lights = [Vec 0 10 0]
          rays = castRays cam planeWidth planeHeight pixelWidth pixelHeight pixelDensity
          colors = map (\x -> traceRay scene x lights 4) rays
          pixels = map vec2pix colors
          imageArray = listArray ((0, 0), (pixelWidth - 1, pixelHeight - 1)) pixels
          img = ImageRGBF $ generateImage (\x y -> imageArray ! (x,y)) pixelWidth pixelHeight