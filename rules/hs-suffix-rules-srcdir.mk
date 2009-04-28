# -----------------------------------------------------------------------------
#
# (c) 2009 The University of Glasgow
#
# This file is part of the GHC build system.
#
# To understand how the build system works and how to modify it, see
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Architecture
#      http://hackage.haskell.org/trac/ghc/wiki/Building/Modifying
#
# -----------------------------------------------------------------------------


define hs-suffix-rules-srcdir
# args: $1 = dir,  $2 = distdir, $3 = way, $4 = srcdir

# Preprocessing Haskell source

$1/$2/build/%.hs : $1/$4/%.ly $$(MKDIRHIER)
	$$(MKDIRHIER) $$(dir $$@)
	$$(HAPPY) $$($1_$2_$3_ALL_HAPPY_OPTS) $$< -o $$@

$1/$2/build/%.hs : $1/$4/%.y $$(MKDIRHIER)
	$$(MKDIRHIER) $$(dir $$@)
	$$(HAPPY) $$($1_$2_$3_ALL_HAPPY_OPTS) $$< -o $$@

$1/$2/build/%.hs : $1/$4/%.x $$(MKDIRHIER)
	$$(MKDIRHIER) $$(dir $$@)
	$$(ALEX) $$($1_$2_$3_ALL_ALEX_OPTS) $$< -o $$@

$1/$2/build/%_hsc.c $1/$2/build/%_hsc.h $1/$2/build/%.hs : $1/$4/%.hsc $$(HSC2HS_INPLACE)
	$$(MKDIRHIER) $$(dir $$@)
	$$(HSC2HS_INPLACE) $$($1_$2_$3_ALL_HSC2HS_OPTS) $$< -o $$@
	touch $$(patsubst %.hsc,%_hsc.c,$$<)

# Compiling Haskell source

$1/$2/build/%.$$($3_osuf) : $1/$4/%.hs $$($1_$2_HC_DEP)
	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@

$1/$2/build/%.$$($3_osuf) : $1/$4/%.lhs $$($1_$2_HC_DEP)
	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@

$1/$2/build/%.$$($3_hcsuf) : $1/$4/%.hs $$($1_$2_HC_DEP)
	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -C $$< -o $$@

$1/$2/build/%.$$($3_hcsuf) : $1/$4/%.lhs $$($1_$2_HC_DEP)
	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -C $$< -o $$@

# XXX: for some reason these get used in preference to the direct
# .hs->.o rule, I don't know why --SDM

# $1/$2/build/%.$$($3_osuf) : $1/$2/build/%.$$($3_way_)hc
# 	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@
#
# $1/$2/build/%.$$($3_osuf) : $1/$2/build/%.hc
# 	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@
#
# $1/$2/build/%.$$($3_way_)s : $1/$2/build/%.$$($3_way_)hc
# 	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -S $$< -o $$@

# Now the rules for hs-boot files.

$1/$2/build/%.hs-boot : $1/$4/%.hs-boot
	$$(CP) $$< $$@

$1/$2/build/%.lhs-boot : $1/$4/%.lhs-boot
	$$(CP) $$< $$@

$1/$2/build/%.$$($3_way_)o-boot : $1/$4/%.hs-boot $$($1_$2_HC_DEP)
	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@

$1/$2/build/%.$$($3_way_)o-boot : $1/$4/%.lhs-boot $$($1_$2_HC_DEP)
	$$($1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@

# stubs are automatically generated and compiled by GHC

$1/$2/build/%_stub.$$($3_osuf): $1/$2/build/%.$$($3_osuf)
	@:

endef
