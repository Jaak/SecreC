{-# LANGUAGE GADTs, FlexibleContexts #-}

module Language.SecreC.TypeChecker.Constraint where

import Language.SecreC.TypeChecker.Base
import {-# SOURCE #-} Language.SecreC.TypeChecker.Expression
import {-# SOURCE #-} Language.SecreC.TypeChecker.Type
import {-# SOURCE #-} Language.SecreC.TypeChecker.Template
import Language.SecreC.Location
import Language.SecreC.Vars
import Language.SecreC.Error
import Language.SecreC.Syntax
import Language.SecreC.Utils

import Control.Monad
import Control.Monad.Except
import qualified Control.Monad.State as State

import Data.Monoid
import Data.Foldable
import qualified Data.Set as Set
import Data.Data

prove :: TcProofM loc a -> TcM loc (Maybe (a,Substs Type))
prove proof = (liftM Just $ tcProofM proof) `mplus` (return Nothing)

-- checks if two types are equal, without using coercions, not performing substitutions
equals :: Location loc => loc -> Type -> Type -> TcProofM loc ()
equals l (ProcType i1 _ _ _) (ProcType i2 _ _ _) | i1 == i2 = return ()
equals l (StructType i1 _ _) (StructType i2 _ _) | i1 == i2 = return ()
equals l (TK c1) (TK c2) = provesCstr mempty (\x y -> return $ mappend x y) equals (const ()) equals l c1 c2
equals l (TK cstr) t2 = do
    t1' <- resolveTK l cstr (Just t2)
    equals l t1' t2
equals l t1 (TK cstr) = do
    t2' <- resolveTK l cstr (Just t1)
    equals l t1 t2'
equals l (TpltType i1 _ _ _ _) (TpltType i2 _ _ _ _) | i1 == i2 = return ()
equals l (TVar (Typed n1 t1)) (TVar (Typed n2 t2)) | n1 == n2 = do
    equals l t1 t2
equals l (TVar v1) t2 = do
    t1' <- resolveTVar l v1
    equals l t1' t2
equals l t1 (TVar v2) = do
    t2' <- resolveTVar l v2
    equals l t1 t2'
equals l (TDim i1) (TDim i2) | i1 == i2 = return ()
equals l TType TType = return ()
equals l KType KType = return ()
equals l (DType i1) (DType i2) | i1 == i2 = return ()
equals l Void Void = return ()
equals l (StmtType s1) (StmtType s2) | s1 == s2 = return ()
equals l (CType s1 t1 dim1 szs1) (CType s2 t2 dim2 szs2) = do
    equals l s1 s2
    equals l t1 t2
    equalsExpr l dim1 dim2
    mapM_ (uncurry (equalsExpr l)) $ zip szs1 szs2
equals l t1 t2@(CType {}) = equals l (defCType t1) t2
equals l t1@(CType {}) t2 = equals l t1 (defCType t2)
equals l (PrimType p1) (PrimType p2) = equalsPrim l p1 p2
equals l Public Public = return ()
equals l (Private d1 k1) (Private d2 k2) | d1 == d2 && k1 == k2 = return ()
equals l (SysPush t1) (SysPush t2) = equals l t1 t2
equals l (SysRet t1) (SysRet t2) = equals l t1 t2
equals l (SysRef t1) (SysRef t2) = equals l t1 t2
equals l (SysCRef t1) (SysCRef t2) = equals l t1 t2
equals l (TyLit l1) (TyLit l2) | l1 == l2 = return ()
equals l t1 t2 = tcError (locpos l) $ EqualityException "types not equal"

equalsFoldable :: (Foldable t,Location loc) => loc -> t Type -> t Type -> TcProofM loc ()
equalsFoldable l xs ys = equalsList l (toList xs) (toList ys)

equalsList :: Location loc => loc -> [Type] -> [Type] -> TcProofM loc ()
equalsList l [] [] = return ()
equalsList l (x:xs) (y:ys) = do
    equals l x y
    equalsList l xs ys
equalsList l xs ys = tcError (locpos l) $ EqualityException "Different number of arguments"

isDefCType :: Location loc => loc -> Type -> TcProofM loc Type
isDefCType l (CType Public t dim []) = equalsExpr l dim (integerExpr 0) >> return t
isDefCType l t = tcError (locpos l) $ EqualityException "non compound type"

equalsPrim :: Location loc => loc -> PrimitiveDatatype () -> PrimitiveDatatype () -> TcProofM loc ()
equalsPrim l p1 p2 | p1 == p2 = return ()
equalsPrim l (DatatypeInt _) (DatatypeInt64 _) = return ()
equalsPrim l (DatatypeInt64 _) (DatatypeInt _) = return ()
equalsPrim l (DatatypeUint _) (DatatypeUint64 _) = return ()
equalsPrim l (DatatypeUint64 _) (DatatypeUint _) = return ()
equalsPrim l (DatatypeXorUint _) (DatatypeXorUint64 _) = return ()
equalsPrim l (DatatypeXorUint64 _) (DatatypeXorUint _) = return ()
equalsPrim l (DatatypeFloat _) (DatatypeFloat32 _) = return ()
equalsPrim l (DatatypeFloat32 _) (DatatypeFloat _) = return ()
equalsPrim l t1 t2 = tcError (locpos l) $ EqualityException $ "Primitive types not equal:\n\t" ++ show t1 ++ "\n\t" ++ show t2

equalsExpr :: Location loc => loc -> Expression () -> Expression () -> TcProofM loc ()
equalsExpr l e1 e2 = do
    (e1',v1) <- evalExpr e1
    (e2',v2) <- evalExpr e2
    unless (v1 == v2 || e1' == e2') $ tcError (locpos l) $ EqualityException $ "Expressions not equal"

provesFoldable :: (Location loc,Foldable t) => b -> (b -> b -> TcProofM loc b) -> (loc -> Type -> Type -> TcProofM loc b) -> loc -> t Type -> t Type -> TcProofM loc b
provesFoldable z plus prove l t1 t2 = provesList z plus prove l (toList t1) (toList t2)

provesList :: (Location loc) => b -> (b -> b -> TcProofM loc b) -> (loc -> Type -> Type -> TcProofM loc b) -> loc -> [Type] -> [Type] -> TcProofM loc b
provesList z plus prove l [] [] = return z
provesList z plus prove l (x:xs) (y:ys) = do
    m1 <- prove l x y
    m2 <- provesList z plus prove l xs ys
    m1 `plus` m2
provesList z plus prove l xs ys = tcError (locpos l) $ EqualityException "Different number of arguments"

-- | tests if two constraint are equal, possibly without resolving them
provesCstr :: (Location loc) => a -> (a -> a -> TcProofM loc a) -> (loc -> Type -> Type -> TcProofM loc a) -> (a -> b) -> (loc -> Type -> Type -> TcProofM loc b) -> loc -> TCstr -> TCstr -> TcProofM loc b
provesCstr z p eq def fallback l c1 c2 = (liftM def (provesCstrEq l c1 c2))
                                 `mplus` (provesCstrNeq l c1 c2)
    where
    provesCstrEq l (TApp n1 args1) (TApp n2 args2) | n1 == n2 = provesFoldable z p eq l args1 args2
    provesCstrEq l (TDec n1 args1) (TDec n2 args2) | n1 == n2 = provesFoldable z p eq l args1 args2
    provesCstrEq l (PApp n1 args1 r1) (PApp n2 args2 r2) | n1 == n2 = provesFoldable z p eq l args1 args2 >> provesFoldable z p eq l r1 r2
    provesCstrEq l (PDec n1 args1 r1) (PDec n2 args2 r2) | n1 == n2 = provesFoldable z p eq l args1 args2 >> provesFoldable z p eq l r1 r2
    provesCstrEq l (SupportedOp o1 t1) (SupportedOp o2 t2) | o1 == o2 = eq l t1 t2
    provesCstrEq l (Coerces a1 b1) (Coerces a2 b2) = eq l a1 a2 >> eq l b1 b2
    provesCstrEq l (Coerces2 a1 b1) (Coerces2 a2 b2) = eq l a1 a2 >> eq l b1 b2
    provesCstrEq l (Declassify x) (Declassify y) = eq l x y
    provesCstrEq l (SupportedSize x) (SupportedSize y) = eq l x y
    provesCstrEq l (SupportedToString x) (SupportedToString y) = eq l x y
    provesCstrEq l (ProjectStruct t1 a1) (ProjectStruct t2 a2) | a1 == a2 = eq l t1 t2
    provesCstrEq l (ProjectMatrix t1 a1) (ProjectMatrix t2 a2) | a1 == a2 = eq l t1 t2 
    provesCstrEq l (Cast a1 b1) (Cast a2 b2) = eq l a1 a2 >> eq l b1 b2
    provesCstrEq l c1 c2 = tcError (locpos l) $ EqualityException "constraints not equal"

    provesCstrNeq l c1 c2 = do
        t1 <- resolveTCstr l c1
        t2 <- resolveTCstr l c2
        fallback l t1 t1

-- checks if two types are equal by applying implicit coercions
-- directed coercion
coerces :: Location loc => loc -> Type -> Type -> TcProofM loc ()
coerces l (ProcType i1 _ _ _) (ProcType i2 _ _ _) | i1 == i2 = return ()
coerces l (StructType i1 _ _) (StructType i2 _ _) | i1 == i2 = return ()
coerces l (TK c1) (TK c2) = provesCstr mempty (\x y -> return $ mappend x y) equals (const ()) coerces l c1 c2
coerces l (TK cstr) t2 = do
    t1' <- resolveTK l cstr (Just t2)
    coerces l t1' t2
coerces l t1 (TK cstr) = do
    t2' <- resolveTK l cstr (Just t1)
    coerces l t1 t2'
coerces l (TpltType i1 _ _ _ _) (TpltType i2 _ _ _ _) | i1 == i2 = return ()
coerces l (TVar (Typed n1 t1)) (TVar (Typed n2 t2)) | n1 == n2 = do
    coerces l t1 t2
coerces l (TVar v1) t2 = do
    t1' <- resolveTVar l v1
    coerces l t1' t2
coerces l t1 (TVar v2) = do
    t2' <- resolveTVar l v2
    coerces l t1 t2'
coerces l (CType s1 t1 dim1 szs1) (CType s2 t2 dim2 szs2) = do
    coerces l s1 s2
    coerces l t1 t2
    equalsExpr l dim1 dim2
    mapM_ (uncurry (equalsExpr l)) $ zip szs1 szs2
coerces l t1@(CType {}) t2 = coerces l t1 (defCType t2)
coerces l t1 t2@(CType {}) = coerces l (defCType t1) t2
coerces l (TDim i1) (TDim i2) | i1 == i2 = return ()
coerces l TType TType = return ()
coerces l KType KType = return ()
coerces l (DType i1) (DType i2) | i1 == i2 = return ()
coerces l Void Void = return ()
coerces l (StmtType s1) (StmtType s2) | Set.difference s1 s2 == Set.empty = return ()
coerces l (PrimType p1) (PrimType p2) = coercesPrim l p1 p2
coerces l Public t2 | typeClass t2 == DomainC = return () -- public coerces into any domain
coerces l (Private d1 k1) (Private d2 k2) | d1 == d2 && k1 == k2 = return ()
coerces l (SysPush t1) (SysPush t2) = coerces l t1 t2
coerces l (SysRet t1) (SysRet t2) = coerces l t1 t2
coerces l (SysRef t1) (SysRef t2) = coerces l t1 t2
coerces l (SysCRef t1) (SysCRef t2) = coerces l t1 t2
coerces l (TyLit lit) t2 = coercesLit l lit t2
coerces l t1 t2 = tcError (locpos l) $ CoercionException $ "Type\n\t" ++ show t1 ++ "\n\tnot coercible into:\n\t" ++ show t2

coercesLit :: Location loc => loc -> Literal () -> Type -> TcProofM loc ()
coercesLit l (IntLit _ i1) (TyLit (IntLit _ i2)) | i1 <= i2 = return ()
coercesLit l (IntLit _ i) (PrimType t) = do
    let (min,max) = primIntBounds t
    unless (min <= i && i <= max) $ tcWarn (locpos l) $ LiteralOutOfRange (show i) (show t) (show min) (show max)
coercesLit l (FloatLit _ f1) (TyLit (FloatLit _ f2)) | f1 <= f2 = return ()
coercesLit l (FloatLit _ f) (PrimType t) = do
    let (min,max) = primFloatBounds t
    unless (min <= f && f <= max) $ tcWarn (locpos l) $ LiteralOutOfRange (show f) (show t) (show min) (show max)
coercesLit l (BoolLit _ b) (PrimType (DatatypeBool _)) = return ()
coercesLit l (StringLit _ s) (PrimType (DatatypeString _)) = return ()
coercesLit l l1 (TyLit l2) | l1 == l2 = return ()
coercesLit l l1 t2 = tcError (locpos l) $ CoercionException $ "Type\n\t" ++ show l1 ++ "\n\tnot coercible into:\n\t" ++ show t2

-- we only support implicit type coercions between integer types
coercesPrim :: Location loc => loc -> PrimitiveDatatype () -> PrimitiveDatatype () -> TcProofM loc ()
coercesPrim l (DatatypeInt8 _) (DatatypeInt16 _) = return ()
coercesPrim l (DatatypeInt8 _) (DatatypeInt32 _) = return ()
coercesPrim l (DatatypeInt8 _) (DatatypeInt64 _) = return ()
coercesPrim l (DatatypeInt8 _) (DatatypeInt _) = return ()
coercesPrim l (DatatypeInt16 _) (DatatypeInt32 _) = return ()
coercesPrim l (DatatypeInt16 _) (DatatypeInt64 _) = return ()
coercesPrim l (DatatypeInt16 _) (DatatypeInt _) = return ()
coercesPrim l (DatatypeInt32 _) (DatatypeInt64 _) = return ()
coercesPrim l (DatatypeInt32 _) (DatatypeInt _) = return ()
coercesPrim l (DatatypeUint8 _) (DatatypeUint16 _) = return ()
coercesPrim l (DatatypeUint8 _) (DatatypeUint32 _) = return ()
coercesPrim l (DatatypeUint8 _) (DatatypeUint64 _) = return ()
coercesPrim l (DatatypeUint8 _) (DatatypeUint _) = return ()
coercesPrim l (DatatypeUint16 _) (DatatypeUint32 _) = return ()
coercesPrim l (DatatypeUint16 _) (DatatypeUint64 _) = return ()
coercesPrim l (DatatypeUint16 _) (DatatypeUint _) = return ()
coercesPrim l (DatatypeUint32 _) (DatatypeUint64 _) = return ()
coercesPrim l (DatatypeUint32 _) (DatatypeUint _) = return ()
coercesPrim l (DatatypeXorUint8 _) (DatatypeXorUint16 _) = return ()
coercesPrim l (DatatypeXorUint8 _) (DatatypeXorUint32 _) = return ()
coercesPrim l (DatatypeXorUint8 _) (DatatypeXorUint64 _) = return ()
coercesPrim l (DatatypeXorUint8 _) (DatatypeXorUint _) = return ()
coercesPrim l (DatatypeXorUint16 _) (DatatypeXorUint32 _) = return ()
coercesPrim l (DatatypeXorUint16 _) (DatatypeXorUint64 _) = return ()
coercesPrim l (DatatypeXorUint16 _) (DatatypeXorUint _) = return ()
coercesPrim l (DatatypeXorUint32 _) (DatatypeXorUint64 _) = return ()
coercesPrim l (DatatypeXorUint32 _) (DatatypeXorUint _) = return ()
coercesPrim l (DatatypeFloat _) (DatatypeFloat64 _) = return ()
coercesPrim l (DatatypeFloat32 _) (DatatypeFloat64 _) = return ()
coercesPrim l t1 t2 = (equalsPrim l t1 t2) `mplus` (tcError (locpos l) $ CoercionException $ "Primitive types not coercible")

-- | bidirectional coercion, no substitutions
coerces2 :: Location loc => loc -> Type -> Type -> TcProofM loc Type
coerces2 l t@(ProcType i1 _ _ _) (ProcType i2 _ _ _) | i1 == i2 = return t
coerces2 l t@(StructType i1 _ _) (StructType i2 _ _) | i1 == i2 = return t
coerces2 l t1@(TK c1) (TK c2) = provesCstr mempty (\x y -> return $ mappend x y) equals (const t1) coerces2 l c1 c2
coerces2 l (TK cstr) t2 = do
    t1' <- resolveTK l cstr (Just t2)
    coerces2 l t1' t2
coerces2 l t1 (TK cstr) = do
    t2' <- resolveTK l cstr (Just t1)
    coerces2 l t1 t2'
coerces2 l t@(TpltType i1 _ _ _ _) (TpltType i2 _ _ _ _) | i1 == i2 = return t
coerces2 l (TVar (Typed n1 t1)) (TVar (Typed n2 t2)) | n1 == n2 = do
    t3 <- coerces2 l t1 t2
    return $ TVar (Typed n1 t3)
coerces2 l (TVar v1) t2 = do
    t1' <- resolveTVar l v1
    coerces2 l t1' t2
coerces2 l t1 (TVar v2) = do
    t2' <- resolveTVar l v2
    coerces2 l t1 t2'
coerces2 l t@(TDim i1) (TDim i2) | i1 == i2 = return t
coerces2 l t@TType TType = return t
coerces2 l t@KType KType = return t
coerces2 l t@(DType k1) (DType k2) | k1 == k2 = return t
coerces2 l t@Void Void = return t
coerces2 l (StmtType s1) (StmtType s2) = return $ StmtType $ Set.union s1 s2
coerces2 l (CType s1 t1 dim1 szs1) (CType s2 t2 dim2 szs2) = do
    s3 <- coerces2 l s1 s2
    t3 <- coerces2 l t1 t2
    equalsExpr l dim1 dim2
    mapM_ (uncurry (equalsExpr l)) $ zip szs1 szs2
    return $ CType s3 t3 dim1 szs1
coerces2 l t1@(CType {}) t2 = coerces2 l t1 (defCType t2)
coerces2 l t1 t2@(CType {}) = coerces2 l (defCType t1) t2
coerces2 l (PrimType p1) (PrimType p2) = do
    p3 <- coercesPrim2 l p1 p2
    return $ PrimType p3
coerces2 l Public t2 | typeClass t2 == DomainC = return t2 -- public coerces into any domain
coerces2 l t1 Public | typeClass t1 == DomainC = return t1 -- public coerces into any domain
coerces2 l t@(Private d1 k1) (Private d2 k2) | d1 == d2 && k1 == k2 = return t
coerces2 l (SysPush t1) (SysPush t2) = do
    t3 <- coerces2 l t1 t2
    return $ SysPush t3
coerces2 l (SysRet t1) (SysRet t2) = do
    t3 <- coerces2 l t1 t2
    return $ SysRet t3
coerces2 l (SysRef t1) (SysRef t2) = do
    t3 <- coerces2 l t1 t2
    return $ SysRef t3
coerces2 l (SysCRef t1) (SysCRef t2) = do
    t3 <- coerces2 l t1 t2
    return $ SysCRef t3
coerces2 l t1@(TyLit lit) t2 = coercesLit2 l t1 t2
coerces2 l t1 t2@(TyLit lit) = coercesLit2 l t1 t2
coerces2 l t1 t2 = tcError (locpos l) $ CoercionException $ "Types not coercible:\n\t" ++ show t1 ++ "\n\t" ++ show t2

coercesPrim2 :: Location loc => loc -> PrimitiveDatatype () -> PrimitiveDatatype () -> TcProofM loc (PrimitiveDatatype ())
coercesPrim2 l t1 t2 | isIntPrimType t1 && isIntPrimType t2 && primIntBounds t1 `within` primIntBounds t2 = return t2
                     | isIntPrimType t1 && isIntPrimType t2 && primIntBounds t2 `within` primIntBounds t1 = return t1
                     | isFloatPrimType t1 && isFloatPrimType t2 && primFloatBounds t1 `within` primFloatBounds t2 = return t2
                     | isFloatPrimType t1 && isFloatPrimType t2 && primFloatBounds t2 `within` primFloatBounds t1 = return t1
coercesPrim2 l t1 t2 = equalsPrim l t1 t2 >> return t1

coercesLit2 :: Location loc => loc -> Type -> Type -> TcProofM loc Type
coercesLit2 l (TyLit (IntLit _ i1)) (TyLit (IntLit _ i2)) = return $ TyLit $ IntLit () (max i1 i2)
coercesLit2 l (TyLit (IntLit _ i)) t2@(PrimType p2) = do
    let (min,max) = primIntBounds p2
    unless (min <= i && i <= max) $ tcWarn (locpos l) $ LiteralOutOfRange (show i) (show t2) (show min) (show max)
    return t2
coercesLit2 l t1@(PrimType p1) (TyLit (IntLit _ i)) = do
    let (min,max) = primIntBounds p1
    unless (min <= i && i <= max) $ tcWarn (locpos l) $ LiteralOutOfRange (show i) (show t1) (show min) (show max)
    return t1  
coercesLit2 l (TyLit (FloatLit _ f1)) (TyLit (FloatLit _ f2)) = return $ TyLit $ FloatLit () (max f1 f2)
coercesLit2 l (TyLit (FloatLit _ f)) t2@(PrimType p2) = do
    let (min,max) = primFloatBounds p2
    unless (min <= f && f <= max) $ tcWarn (locpos l) $ LiteralOutOfRange (show f) (show t2) (show min) (show max)
    return t2
coercesLit2 l t1@(PrimType p1) (TyLit (FloatLit _ f)) = do
    let (min,max) = primFloatBounds p1
    unless (min <= f && f <= max) $ tcWarn (locpos l) $ LiteralOutOfRange (show f) (show t1) (show min) (show max)
    return t1        
coercesLit2 l (TyLit (BoolLit _ b)) t2@(PrimType (DatatypeBool _)) = return t2
coercesLit2 l t1@(PrimType (DatatypeBool _)) (TyLit (BoolLit _ b)) = return t1
coercesLit2 l (TyLit (StringLit _ s)) t2@(PrimType (DatatypeString _)) = return t2
coercesLit2 l t1@(PrimType (DatatypeString _)) (TyLit (StringLit _ s)) = return t1
coercesLit2 l t1@(TyLit l1) (TyLit l2) | l1 == l2 = return t1
coercesLit2 l t1 t2 = tcError (locpos l) $ CoercionException $ "Types not coercible\n\t" ++ show t1 ++ "\n\t" ++ show t2

-- | Checks if a type is more specific than another, performing substitutions
compares :: Location loc => loc -> Type -> Type -> TcProofM loc Ordering
compares l t1@(TVar v1) t2@(TVar v2) = provesVar EQ compares l v2 t1
compares l (TVar v1) t2 = provesVar GT compares l v1 t2
compares l t1 (TVar v2) = provesVar LT compares l v2 t1
compares l (ProcType i1 _ _ _) (ProcType i2 _ _ _) | i1 == i2 = return EQ
compares l (StructType i1 _ _) (StructType i2 _ _) | i1 == i2 = return EQ
compares l (TpltType i1 _ _ _ _) (TpltType i2 _ _ _ _) | i1 == i2 = return EQ
compares l (TK c1) (TK c2) = provesCstr EQ (appendOrdering l) compares id compares l c1 c2
compares l (TK c1) t2 = do
    t1' <- resolveTK l c1 (Just t2)
    compares l t1' t2
compares l t1 (TK c2) = do
    t2' <- resolveTK l c2 (Just t1)
    compares l t1 t2'
compares l (TDim i1) (TDim i2) | i1 == i2 = return EQ
compares l TType TType = return EQ
compares l KType KType = return EQ
compares l (DType k1) (DType k2) | k1 == k2 = return EQ
compares l Void Void = return EQ
compares l (StmtType s1) (StmtType s2) | s1 == s2 = return EQ
compares l (CType s1 t1 dim1 szs1) (CType s2 t2 dim2 szs2) = do
        o1 <- compares l s1 s2
        o2 <- compares l t1 t2
        equalsExpr l dim1 dim2
        mapM_ (uncurry (equalsExpr l)) $ zip szs1 szs2
        appendOrdering l o1 o2
compares l t1@(CType {}) t2 = compares l t1 (defCType t2)
compares l t1 t2@(CType {}) = compares l (defCType t1) t2
compares l Public Public = return EQ
compares l (Private d1 k1) (Private d2 k2) | d1 == d2 && k1 == k2 = return EQ
compares l (SysPush t1) (SysPush t2) = compares l t1 t2
compares l (SysRet t1) (SysRet t2) = compares l t1 t2
compares l (SysRef t1) (SysRef t2) = compares l t1 t2
compares l (SysCRef t1) (SysCRef t2) = compares l t1 t2
compares l (TyLit lit1) (TyLit lit2) | lit1 == lit2 = return EQ
compares l (TyLit lit) t2 = coercesLit l lit t2 >> return GT
compares l t1 (TyLit lit) = coercesLit l lit t1 >> return LT
compares l (PrimType p1) (PrimType p2) = (equalsPrim l p1 p2 >> return EQ) `mplus` (tcError (locpos l) $ ComparisonException "Primitive types not comparable")
compares l t1 t2 = tcError (locpos l) $ ComparisonException "Types not comparable"
    
comparesFoldable :: (Foldable t,Location loc) => loc -> t Type -> t Type -> TcProofM loc Ordering
comparesFoldable l xs ys = comparesList l (toList xs) (toList ys)

comparesList :: Location loc => loc -> [Type] -> [Type] -> TcProofM loc Ordering
comparesList l [] [] = return EQ
comparesList l (x:xs) (y:ys) = do
    f <- compares l x y
    g <- comparesList l xs ys
    appendOrdering l f g
comparesList l xs ys = tcError (locpos l) $ ComparisonException "Different number of arguments"
    
appendOrdering :: Location loc => loc -> Ordering -> Ordering -> TcProofM loc Ordering
appendOrdering l EQ y = return y
appendOrdering l x EQ = return x
appendOrdering l LT LT = return LT
appendOrdering l GT GT = return GT
appendOrdering l x y = tcError (locpos l) $ ComparisonException "Non-comparable types"
    
-- | Non-directed unification, without coercions
-- takes a type variable for the result of the unification
-- applies substitutions
unifies :: Location loc => loc -> Type -> Type -> TcProofM loc ()
unifies l t1@(TVar v1) t2 = provesVar () unifies l v1 t2
unifies l t1 t2@(TVar v2) = provesVar () unifies l v2 t1
unifies l (ProcType i1 _ _ _) (ProcType i2 _ _ _) | i1 == i2 = return ()
unifies l (StructType i1 _ _) (StructType i2 _ _) | i1 == i2 = return ()
unifies l (TK c1) (TK c2) = provesCstr mempty (\x y -> return $ mappend x y) unifies (const ()) unifies l c1 c2
unifies l (TK c1) t2 = do
    t1' <- resolveTK l c1 (Just t2)
    unifies l t1' t2
unifies l t1 (TK c2) = do
    t2' <- resolveTK l c2 (Just t1)
    unifies l t1 t2'
unifies l (TpltType i1 _ _ _ _) (TpltType i2 _ _ _ _) | i1 == i2 = return ()
unifies l (TDim i1) (TDim i2) | i1 == i2 = return ()
unifies l TType TType = return ()
unifies l KType KType = return ()
unifies l (DType k1) (DType k2) | k1 == k2 = return ()
unifies l Void Void = return ()
unifies l (StmtType s1) (StmtType s2) | s1 == s2 = return ()
unifies l (CType s1 t1 dim1 szs1) (CType s2 t2 dim2 szs2) = do
    s3 <- unifies l s1 s2
    t3 <- unifies l t1 t2
    equalsExpr l dim1 dim2
    mapM_ (uncurry (equalsExpr l)) $ zip szs1 szs2
unifies l t1@(CType {}) t2 = unifies l t1 (defCType t2)
unifies l t1 t2@(CType {}) = unifies l (defCType t1) t2
unifies l (PrimType p1) (PrimType p2) = (equalsPrim l p1 p2) `mplus` (tcError (locpos l) $ UnificationException $ "Primitive types not unifiable")
unifies l Public Public = return ()
unifies l (Private d1 k1) (Private d2 k2) | d1 == d2 && k1 == k2 = return ()
unifies l (SysPush t1) (SysPush t2) = unifies l t1 t2
unifies l (SysRet t1) (SysRet t2) = unifies l t1 t2
unifies l (SysRef t1) (SysRef t2) = unifies l t1 t2
unifies l (SysCRef t1) (SysCRef t2) = unifies l t1 t2
unifies l (TyLit lit) t2 = coercesLit l lit t2
unifies l t1 (TyLit lit) = coercesLit l lit t1
unifies l t1 t2 = tcError (locpos l) $ UnificationException $ "Types not unifiable"

provesVar :: Location loc => b -> (loc -> Type -> Type -> TcProofM loc b) -> loc -> Typed VarIdentifier -> Type -> TcProofM loc b
provesVar z go l v1 t2 = do
    mb <- tryResolveTVar l v1
    case mb of
        Nothing -> if typeClass (TVar v1) == typeClass t2
            then addSubstM [(v1,t2)] >> return z
            else tcError (locpos l) $ UnificationException "different type classes"
        Just t1' -> go l t1' t2

unifiesFoldable :: (Foldable t,Location loc) => loc -> t Type -> t Type -> TcProofM loc ()
unifiesFoldable l xs ys = unifiesList l (toList xs) (toList ys)

unifiesList :: Location loc => loc -> [Type] -> [Type] -> TcProofM loc ()
unifiesList l [] [] = return ()
unifiesList l (x:xs) (y:ys) = do
    unifies l x y
    unifiesList l xs ys
unifiesList l xs ys = tcError (locpos l) $ UnificationException "Different number of arguments"

-- | Tries to resolve a constraint inside a proof
resolveTK :: Location loc => loc -> TCstr -> Maybe Type -> TcProofM loc Type
resolveTK l (PApp n args (Just r)) _ = return r -- we just want the return type
resolveTK l cstr@(PApp n args Nothing) (Just t) = do -- we just want the return type
    lift $ remTemplateConstraint cstr -- remove the old constraint
    tcCstr l $ PApp n args (Just t) -- throw the new constraint; it does not need to be resolved
    return t
resolveTK l cstr@(PDec n args Nothing) (Just t) = do
    lift $ remTemplateConstraint cstr  -- remove the old constraint
    resolveTCstr l $ PDec n args (Just t) -- resolve new constraint
resolveTK l cstr t = resolveTCstr l cstr

resolveTVar :: Location loc => loc -> Typed VarIdentifier -> TcProofM loc Type
resolveTVar l v = do
    mb <- tryResolveTVar l v
    case mb of
        Nothing -> tcError (locpos l) $ EqualityException "cannot resolve variable"
        Just t -> return t

-- | tries to resolve a type variable by looking its value in the substitutions and in the environment
tryResolveTVar :: Location loc => loc -> Typed VarIdentifier -> TcProofM loc (Maybe Type)
tryResolveTVar l v = do
    s <- State.get
    return (s v)

-- typechecks a constraint
tcCstr :: Location loc => loc -> TCstr -> TcProofM loc (Maybe Type)
tcCstr l cstr = do
    b <- lift insideTemplate
    if (b && isContextTCstr cstr) -- if inside a template and the constraint depends on the context
        then do -- delay its resolution
            lift $ addTemplateConstraint cstr Nothing
            return Nothing
        else liftM Just $ resolveTCstr l cstr -- resolve the constraint

tcCstrM :: Location loc => loc -> TCstr -> TcM loc Type
tcCstrM l c = do
    (mb,s) <- tcProofM $ tcCstr l c
    case mb of
        Nothing -> return $ TK c
        Just x -> return x

resolveTCstr :: Location loc => loc -> TCstr -> TcProofM loc Type
resolveTCstr l k@(TApp n args) =
    liftM fst $ lift $ matchTemplate l (Left n) args Nothing (checkTemplateType (TypeName l n))
resolveTCstr l k@(TDec n args) =
    liftM snd $ lift $ matchTemplate l (Left n) args Nothing (checkTemplateType (TypeName l n))
resolveTCstr l k@(PApp n args r) =
    liftM fst $ lift $ matchTemplate l (Right n) args r (checkProcedure (ProcedureName l n))
resolveTCstr l k@(PDec n args r) =
    liftM snd $ lift $ matchTemplate l (Right n) args r (checkProcedure (ProcedureName l n))
resolveTCstr l k@(SupportedOp op t) = do
    ret <- isSupportedOp l op t
    lift $ addTemplateConstraint k (Just ret)
    return ret
resolveTCstr l k@(Coerces t1 t2) = do
    coerces l t1 t2
    lift $ addTemplateConstraint k (Just NoType)
    return NoType
resolveTCstr l k@(Coerces2 t1 t2) = do
    ret <- coerces2 l t1 t2
    lift $ addTemplateConstraint k (Just ret)
    return ret
resolveTCstr l k@(Declassify t) = do
    ret <- declassifyType l t
    lift $ addTemplateConstraint k (Just ret)
    return ret
resolveTCstr l k@(SupportedSize t) = do
    isSupportedSize l t
    lift $ addTemplateConstraint k (Just NoType)
    return NoType
resolveTCstr l k@(SupportedToString t) = do
    isSupportedToString l t
    lift $ addTemplateConstraint k (Just NoType)
    return NoType
resolveTCstr l k@(ProjectStruct t a) = do
    ret <- projectStructField l t a
    lift $ addTemplateConstraint k (Just ret)
    return ret
resolveTCstr l k@(ProjectMatrix t rs) = do
    ret <- projectMatrixType l t rs
    lift $ addTemplateConstraint k (Just ret)
    return ret
resolveTCstr l k@(Cast t1 t2) = do
    castType l t1 t2
    lift $ addTemplateConstraint k (Just NoType)
    return NoType
    
-- | tests if a constraint depends on the context
isContextTCstr :: TCstr -> Bool
isContextTCstr (TApp {}) = True -- because of overloading
isContextTCstr (TDec {}) = True -- because of overloading
isContextTCstr (PApp {}) = True -- because of overloading
isContextTCstr (PDec {}) = True -- because of overloading
isContextTCstr (SupportedOp op t) = True -- because of overloading
isContextTCstr (Coerces t1 t2) = hasTypeVars t1 || hasTypeVars t2
isContextTCstr (Coerces2 t1 t2) = hasTypeVars t1 || hasTypeVars t2
isContextTCstr (Declassify t) = True -- because of overloading
isContextTCstr (SupportedSize t) = hasTypeVars t
isContextTCstr (SupportedToString t) = hasTypeVars t
isContextTCstr (ProjectStruct (StructType {}) a) = False
isContextTCstr (ProjectStruct t a) = True
isContextTCstr (ProjectMatrix (CType {}) a) = False
isContextTCstr (ProjectMatrix t a) = True
isContextTCstr (Cast t1 t2) = True -- because of overloading

-- declassifies 
declassifyType :: Location loc => loc -> Type -> TcProofM loc Type
declassifyType l (CType _ t d sz) = return $ CType Public t d sz
declassifyType l t | typeClass t == TypeC = return t
                 | otherwise = tcError (locpos l) $ NonDeclassifiableExpression

-- | Operation supported over the given type
isSupportedOp :: Location loc => loc -> Op () -> Type -> TcProofM loc Type
isSupportedOp l o@(OpDiv ()) t = if (isIntType t) then return t else tcError (locpos l) $ NonSupportedOperation o (show t)
isSupportedOp l o@(OpMod ()) t = if (isIntType t) then return t else tcError (locpos l) $ NonSupportedOperation o (show t)
isSupportedOp l o@(OpMul ()) t = if (isNumericType t) then return t else tcError (locpos l) $ NonSupportedOperation o (show t)
isSupportedOp l o@(OpAdd ()) t = if (isNumericType t) then return t else tcError (locpos l) $ NonSupportedOperation o (show t)
isSupportedOp l o@(OpSub ()) t = if (isNumericType t) then return t else tcError (locpos l) $ NonSupportedOperation o (show t)
isSupportedOp l o@(OpBand ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpBor ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpXor ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpGt ()) t = return $ PrimType $ DatatypeBool () -- work over any type
isSupportedOp l o@(OpLt ()) t = return $ PrimType $ DatatypeBool () -- work over any type
isSupportedOp l o@(OpEq ()) t = return $ PrimType $ DatatypeBool () -- work over any type
isSupportedOp l o@(OpGe ()) t = return $ PrimType $ DatatypeBool () -- work over any type
isSupportedOp l o@(OpLe ()) t = return $ PrimType $ DatatypeBool () -- work over any type
isSupportedOp l o@(OpLand ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpLor ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpNe ()) t = return $ PrimType $ DatatypeBool ()
isSupportedOp l o@(OpShl ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpShr ()) t = error "isSupportedOp" -- TODO
isSupportedOp l o@(OpNot ()) t = if isBoolType t then return t else tcError (locpos l) $ NonSupportedOperation o (show t)

isSupportedSize :: Location loc => loc -> Type -> TcProofM loc ()
isSupportedSize l t | typeClass t /= TypeC || t == Void = tcError (locpos l) InvalidSizeArgument
isSupportedSize l t = return ()

isSupportedToString :: Location loc => loc -> Type -> TcProofM loc ()
isSupportedToString l t | typeClass t /= TypeC || t == Void = tcError (locpos l) InvalidToStringArgument
isSupportedToString l (CType s t dim sz) | isPublicType s = equalsExpr l (integerExpr 1) dim
isSupportedToString l t = tcError (locpos l) InvalidToStringArgument
