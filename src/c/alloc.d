
/*
    alloc.c --	Memory allocation.
*/
/*
    Copyright (c) 1984, Taiichi Yuasa and Masami Hagiya.
    Copyright (c) 1990, Giuseppe Attardi.
    Copyright (c) 2001, Juan Jose Garcia Ripoll.

    ECL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    See file '../Copyright' for full details.
*/


/*
  			Heap and Relocatable Area

	                 heap_end    data_end
    +------+--------------------+ - - - + - - --------+
    | text |        heap        | hole  |      stack  |
    +------+--------------------+ - - - + - - --------+

   The type_map array covers all pages of memory: those not used for objects
   are marked as type t_other.

   The tm_table array holds a struct typemanager for each type, which contains
   the first element of the free list for the type, and other bookkeeping
   information.
*/

#include <unistd.h>
#include "ecl.h"
#include "page.h"

#undef USE_MMAP
#ifdef USE_MMAP
#include <sys/types.h>
#include <sys/mman.h>
#endif

#ifdef BSD
#include <sys/resource.h>
#endif
#ifdef SYSV
#include <ulimit.h>
#endif

/******************************* EXPORTS ******************************/

cl_index real_maxpage;
cl_index new_holepage;
char type_map[MAXPAGE];
struct typemanager tm_table[(int)t_end];
struct contblock *cb_pointer = NULL;

cl_index ncb;			/*  number of contblocks  */
cl_index ncbpage;		/*  number of contblock pages  */
cl_index maxcbpage;		/*  maximum number of contblock pages  */
cl_index cbgccount;		/*  contblock gc count  */
cl_index holepage;		/*  hole pages  */

cl_ptr heap_end;		/*  heap end  */
cl_ptr heap_start;		/*  heap start  */
cl_ptr data_end;		/*  end of data space  */

/******************************* ------- ******************************/

static bool ignore_maximum_pages = TRUE;

#ifdef NEED_MALLOC
static cl_object malloc_list;
#endif

/*
   Ensure that the hole is at least "n" pages large. If it is not,
   allocate space from the operating system.
*/

#if defined(USE_MMAP)
void
cl_resize_hole(cl_index n)
{
	cl_index m, bytes;
	cl_ptr result, last_addr;
	if (heap_start == NULL) {
		/* First time use. We allocate the memory and keep the first
		 * address in heap_start.
		 */
		bytes = n * LISP_PAGESIZE;
		result = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
			      MAP_ANON | MAP_PRIVATE, -1 ,0);
		if (result == MAP_FAILED)
			error("Cannot allocate memory. Good-bye!");
		data_end = heap_end = heap_start = result;
		last_addr = heap_start + bytes;
		holepage = n;
	} else {
		/* Next time use. We extend the region of memory that we had
		 * mapped before.
		 */
		m = (data_end - heap_end)/LISP_PAGESIZE;
		if (n <= m)
			return;
		bytes = n * LISP_PAGESIZE;
		result = mmap(data_end, bytes, PROT_READ | PROT_WRITE,
			      MAP_ANON | MAP_PRIVATE, -1, 0);
		if (result == MAP_FAILED)
			error("Cannot resize memory pool. Good-bye!");
		last_addr = result + bytes;
		if (result != data_end) {
			cl_dealloc(heap_end, data_end - heap_end);
			while (heap_end < result) {
				cl_index p = page(heap_end);
				if (p > real_maxpage)
					error("Memory limit exceeded.");
				type_map[p] = t_other;
				heap_end += LISP_PAGESIZE;
			}
		}
		holepage = (last_addr - heap_end) / LISP_PAGESIZE;
	}
	while (data_end < last_addr) {
		type_map[page(data_end)] = t_other;
		data_end += LISP_PAGESIZE;
	}
}
#else
void
cl_resize_hole(cl_index n)
{
	cl_ptr e;
	cl_index m;
	m = (data_end - heap_end)/LISP_PAGESIZE;
	if (n <= m)
	  return;

	/* Create the hole */
	e = sbrk(0);
	if (data_end == e)
	  n -= m;
	else {
 	  cl_dealloc(heap_end, data_end - heap_end);
	  /* FIXME! Horrible hack! */
	  /* mark as t_other pages not allocated by us */
	  heap_end = e;
	  while (data_end < heap_end) {
	    type_map[page(data_end)] = t_other;
	    data_end += LISP_PAGESIZE;
	  }
	  holepage = 0;
	}
	if ((int)sbrk(LISP_PAGESIZE * n) < 0)
	  error("Can't allocate.  Good-bye!");
	data_end += LISP_PAGESIZE*(n);
	holepage += n;
}
#endif

/* Allocates n pages from the hole.  */
static void *
alloc_page(cl_index n)
{
	cl_ptr e = heap_end;
	if (n >= holepage) {
	  gc(t_contiguous);
	  cl_resize_hole(new_holepage+n);
	}
	holepage -= n;
	heap_end += LISP_PAGESIZE*n;
	return e;
}

static void
add_page_to_freelist(cl_ptr p, struct typemanager *tm)
{ cl_type t;
  cl_object x, f;
  cl_index i;
  t = tm->tm_type;
  type_map[page(p)] = t;
  f = tm->tm_free;
  for (i = tm->tm_nppage; i > 0; --i, p += tm->tm_size) {
    x = (cl_object)p;
    ((struct freelist *)x)->t = (short)t;
    ((struct freelist *)x)->m = FREE;
    ((struct freelist *)x)->f_link = f;
    f = x;
  }
  tm->tm_free = f;
  tm->tm_nfree += tm->tm_nppage;
  tm->tm_npage++;
}

cl_object
cl_alloc_object(cl_type t)
{
	register cl_object obj;
	register struct typemanager *tm;
	register cl_ptr p;

	switch (t) {
	case t_fixnum:
	  return MAKE_FIXNUM(0); /* Immediate fixnum */
	case t_character:
	  return CODE_CHAR('\0'); /* Immediate character */
	}
	
	start_critical_section(); 
	tm = tm_of(t);
ONCE_MORE:
	if (interrupt_flag) {
		interrupt_flag = FALSE;
#ifdef unix
		alarm(0);
#endif
		terminal_interrupt(TRUE);
	}

	obj = tm->tm_free;
	if (obj == OBJNULL) {
		cl_index available = available_pages();
		if (tm->tm_npage >= tm->tm_maxpage)
			goto CALL_GC;
		if (available < 1) {
			ignore_maximum_pages = FALSE;
			goto CALL_GC;
		}
		p = alloc_page(1);
		add_page_to_freelist(p, tm);
		obj = tm->tm_free;
		/* why this? Beppe
		if (tm->tm_npage >= tm->tm_maxpage)
			goto CALL_GC; */
	}
	tm->tm_free = ((struct freelist *)obj)->f_link;
	--(tm->tm_nfree);
	(tm->tm_nused)++;
	obj->d.t = (short)t;
	obj->d.m = FALSE;
	/* Now initialize the object so that it can be correctly marked
	 * by the GC
	 */
	switch (t) {
	case t_bignum:
	  obj->big.big_dim = obj->big.big_size = 0;
	  obj->big.big_limbs = NULL;
	  break;
	case t_ratio:
	  obj->ratio.num = OBJNULL;
	  obj->ratio.den = OBJNULL;
	  break;
	case t_shortfloat:
	case t_longfloat:
	  break;
	case t_complex:
	  obj->complex.imag = OBJNULL;
	  obj->complex.real = OBJNULL;
	  break;
	case t_symbol:
	  obj->symbol.plist = OBJNULL;
	  SYM_FUN(obj) = OBJNULL;
	  SYM_VAL(obj) = OBJNULL;
	  obj->symbol.name = OBJNULL;
	  break;
	case t_package:
	  obj->pack.name = OBJNULL;
	  obj->pack.nicknames = OBJNULL;
	  obj->pack.shadowings = OBJNULL;
	  obj->pack.uses = OBJNULL;
	  obj->pack.usedby = OBJNULL;
	  obj->pack.internal = OBJNULL;
	  obj->pack.external = OBJNULL;
	  break;
	case t_cons:
	  CAR(obj) = OBJNULL;
	  CDR(obj) = OBJNULL;
	  break;
	case t_hashtable:
	  obj->hash.rehash_size = OBJNULL;
	  obj->hash.threshold = OBJNULL;
	  obj->hash.data = NULL;
	  break;
	case t_array:
	  obj->array.displaced = Cnil;
	  obj->array.elttype = (short)aet_object;
	  obj->array.self.t = NULL;
	  break;
	case t_vector:
	  obj->array.displaced = Cnil;
	  obj->array.elttype = (short)aet_object;
	  obj->array.self.t = NULL;
	  break;
	case t_string:
	  obj->string.displaced = Cnil;
	  obj->string.self = NULL;
	  break;
	case t_bitvector:
	  obj->vector.displaced = Cnil;
	  obj->vector.self.bit = NULL;
	  break;
#ifndef CLOS
	case t_structure:
	  obj->str.name = OBJNULL;
	  obj->str.self = NULL;
	  break;
#endif /* CLOS */
	case t_stream:
	  obj->stream.mode = (short)smm_closed;
	  obj->stream.file = NULL;
	  obj->stream.object0 = OBJNULL;
	  obj->stream.object1 = OBJNULL;
	  obj->stream.buffer = NULL;
	  break;
	case t_random:
	  break;
	case t_readtable:
	  obj->readtable.table = NULL;
	  break;
	case t_pathname:
	  obj->pathname.host = OBJNULL;
	  obj->pathname.device = OBJNULL;
	  obj->pathname.directory = OBJNULL;
	  obj->pathname.name = OBJNULL;
	  obj->pathname.type = OBJNULL;
	  obj->pathname.version = OBJNULL;
	  break;
	case t_bytecodes:
	  obj->bytecodes.lex = Cnil;
	  obj->bytecodes.size = 0;
	  obj->bytecodes.data = NULL;
	  break;
	case t_cfun:
	  obj->cfun.name = OBJNULL;
	  obj->cfun.block = NULL;
	  break;
	case t_cclosure:
	  obj->cclosure.env = OBJNULL;
	  obj->cclosure.block = NULL;
	  break;
/*
	case t_spice:
	  break;
*/
#ifdef THREADS
	case t_cont:
	  obj->cn.cn_thread = OBJNULL;
	  break;
	case t_thread:
	  obj->thread.entry = OBJNULL;
	  break;
#endif
#ifdef CLOS
	case t_instance:
	  CLASS_OF(obj) = OBJNULL;
	  obj->instance.slots = NULL;
	  break;
	case t_gfun:
	  obj->gfun.name = OBJNULL;
	  obj->gfun.method_hash = OBJNULL;
	  obj->gfun.instance = OBJNULL;
	  obj->gfun.specializers = NULL;
	  break;
#endif /* CLOS */
	case t_codeblock:
	  obj->cblock.name = Cnil;
	  obj->cblock.handle = NULL;
	  obj->cblock.entry = NULL;
	  obj->cblock.data = NULL;
	  obj->cblock.data_size = 0;
	  obj->cblock.data_text = NULL;
	  obj->cblock.data_text_size = 0;
	  break;
	default:
	  printf("\ttype = %d\n", t);
	  error("alloc botch.");
	}
#ifdef THREADS
	clwp->lwp_alloc_temporary = obj;
#endif
	end_critical_section();
	return(obj);
CALL_GC:
	gc(tm->tm_type);
	if (tm->tm_nfree != 0 &&
		(float)tm->tm_nfree * 10.0 >= (float)tm->tm_nused)
		goto ONCE_MORE;

/*	EXHAUSTED:	*/
	if (ignore_maximum_pages) {
		if (tm->tm_maxpage/2 <= 0)
			tm->tm_maxpage += 1;
		else
			tm->tm_maxpage += tm->tm_maxpage/2;
		goto ONCE_MORE;
	}
	GC_disable();
	{ cl_object s = make_simple_string(tm_table[(int)t].tm_name+1);
	GC_enable();
	CEerror("The storage for ~A is exhausted.~%\
Currently, ~D pages are allocated.~%\
Use ALLOCATE to expand the space.",
		2, s, MAKE_FIXNUM(tm->tm_npage));
	}
	goto ONCE_MORE;
}

cl_object
make_cons(cl_object a, cl_object d)
{
	register cl_object obj;
	register cl_ptr p;
	struct typemanager *tm=(&tm_table[(int)t_cons]);

	start_critical_section(); 

ONCE_MORE:
	if (interrupt_flag) {
		interrupt_flag = FALSE;
#ifdef unix
		alarm(0);
#endif
		terminal_interrupt(TRUE);
	}
	obj = tm->tm_free;
	if (obj == OBJNULL) {
		if (tm->tm_npage >= tm->tm_maxpage)
			goto CALL_GC;
		if (available_pages() < 1) {
			ignore_maximum_pages = FALSE;
			goto CALL_GC;
		}
		p = alloc_page(1);
		add_page_to_freelist(p,tm);
		obj = tm->tm_free;
		if (tm->tm_npage >= tm->tm_maxpage)
			goto CALL_GC;
	}
	tm->tm_free = ((struct freelist *)obj)->f_link;
	--(tm->tm_nfree);
	(tm->tm_nused)++;
	obj->d.t = (short)t_cons;
	obj->d.m = FALSE;
	CAR(obj) = a;
	CDR(obj) = d;

	end_critical_section();
	return(obj);

CALL_GC:
	gc(t_cons);
	if ((tm->tm_nfree != 0) && (tm->tm_nfree * 10.0 >= tm->tm_nused))
		goto ONCE_MORE;

/*	EXHAUSTED:	*/
	if (ignore_maximum_pages) {
		if (tm->tm_maxpage/2 <= 0)
			tm->tm_maxpage += 1;
		else
			tm->tm_maxpage += tm->tm_maxpage/2;
		goto ONCE_MORE;
	}
	CEerror("The storage for CONS is exhausted.~%\
Currently, ~D pages are allocated.~%\
Use ALLOCATE to expand the space.",
		1, MAKE_FIXNUM(tm->tm_npage));
	goto ONCE_MORE;
#undef	tm
}

cl_object
cl_alloc_instance(cl_index slots)
{
	cl_object i = cl_alloc_object(t_instance);
	/* INV: slots > 0 */
	i->instance.slots = (cl_object*)cl_alloc(sizeof(cl_object) * slots);
	i->instance.length = slots;
	return i;
}

void *
cl_alloc(cl_index n)
{
	volatile cl_ptr p;
	struct contblock **cbpp;
	cl_index i, m;
	bool g, gg;

	g = FALSE;
	n = round_up(n);

	start_critical_section(); 

ONCE_MORE:
	if (interrupt_flag) {
		interrupt_flag = FALSE;
		gg = g;
		terminal_interrupt(TRUE);
		g = gg;
	}

	/* Use extra indirection so that cb_pointer can be updated */
	for (cbpp = &cb_pointer; (*cbpp) != NULL; cbpp = &(*cbpp)->cb_link) 
		if ((*cbpp)->cb_size >= n) {
			p = (cl_ptr)(*cbpp);
			i = (*cbpp)->cb_size - n;
			*cbpp = (*cbpp)->cb_link;
			--ncb;
			cl_dealloc(p+n, i);

			end_critical_section();
			return(p);
		}
	m = round_to_page(n);
	if (ncbpage + m > maxcbpage || available_pages() < m) {
		if (available_pages() < m)
			ignore_maximum_pages = FALSE;
		if (!g) {
			gc(t_contiguous);
			g = TRUE;
			goto ONCE_MORE;
		}
		if (ignore_maximum_pages) {
			if (maxcbpage/2 <= 0)
				maxcbpage += 1;
			else
				maxcbpage += maxcbpage/2;
			g = FALSE;
			goto ONCE_MORE;
		}
		CEerror("Contiguous blocks exhausted.~%\
Currently, ~D pages are allocated.~%\
Use ALLOCATE-CONTIGUOUS-PAGES to expand the space.",
			1, MAKE_FIXNUM(ncbpage));
		g = FALSE;
		goto ONCE_MORE;
	}
	p = alloc_page(m);

	for (i = 0;  i < m;  i++)
		type_map[page(p) + i] = (char)t_contiguous;
	ncbpage += m;
	cl_dealloc(p+n, LISP_PAGESIZE*m - n);

	end_critical_section();
	return(p);
}

/*
 * adds a contblock to the list of available ones, pointed by cb_pointer,
 * sorted by increasing size.
 */
void
cl_dealloc(void *p, cl_index s)
{
	struct contblock **cbpp, *cbp;

	if (s < CBMINSIZE)
		return;
	ncb++;
	cbp = (struct contblock *)p;
	cbp->cb_size = s;
	for (cbpp = &cb_pointer; *cbpp != NULL; cbpp = &((*cbpp)->cb_link))
		if ((*cbpp)->cb_size >= s) {
			cbp->cb_link = *cbpp;
			*cbpp = cbp;
			return;
		}
	cbp->cb_link = NULL;
	*cbpp = cbp;
}

/*
 * align must be a power of 2 representing the alignment boundary
 * required for the block.
 */
void *
cl_alloc_align(cl_index size, cl_index align)
{
	void *output;
	start_critical_section();
	align--;
	output = (void*)(((cl_index)cl_alloc(size + align) + align - 1) & ~align)
	end_critical_section();
	return output;
}

static void
init_tm(cl_type t, char *name, cl_index elsize, cl_index maxpage)
{
	int i, j;
	struct typemanager *tm = &tm_table[(int)t];

	tm->tm_name = name;
	for (i = (int)t_start, j = i-1;  i < (int)t_end;  i++)
	  if (tm_table[i].tm_size >= elsize &&
	      (j < (int)t_start || tm_table[j].tm_size > tm_table[i].tm_size))
	    j = i;
	if (j >= (int)t_start) {
		tm->tm_type = (cl_type)j;
		tm_table[j].tm_maxpage += maxpage;
		return;
	}
	tm->tm_type = t;
	tm->tm_size = round_up(elsize);
	tm->tm_nppage = LISP_PAGESIZE/round_up(elsize);
	tm->tm_free = OBJNULL;
	tm->tm_nfree = 0;
	tm->tm_nused = 0;
	tm->tm_npage = 0;
	tm->tm_maxpage = maxpage;
	tm->tm_gccount = 0;
}

static int alloc_initialized = FALSE;

void
init_alloc(void)
{
	cl_index i;

	if (alloc_initialized) return;
	alloc_initialized = TRUE;

	holepage = 0;
	new_holepage = HOLEPAGE;

#ifdef USE_MMAP
	real_maxpage = MAXPAGE;
#elif defined(MSDOS) || defined(__CYGWIN__)
	real_maxpage = MAXPAGE;
#elif defined(BSD)
	{
	  struct rlimit data_rlimit;
# ifdef __MACH__
	  sbrk(0);
	  getrlimit(RLIMIT_DATA, &data_rlimit);
	  real_maxpage = ((unsigned)get_etext() +
			  (unsigned)data_rlimit.rlim_cur)/LISP_PAGESIZE;
# else
	  extern etext;

	  getrlimit(RLIMIT_DATA, &data_rlimit);
	  real_maxpage = ((unsigned int)&etext +
			  (unsigned)data_rlimit.rlim_cur)/LISP_PAGESIZE;
# endif
	  if (real_maxpage > MAXPAGE) real_maxpage = MAXPAGE;
	}
#elif defined(SYSV)
	real_maxpage= ulimit(UL_GMEMLIM)/LISP_PAGESIZE;
	if (real_maxpage > MAXPAGE) real_maxpage = MAXPAGE;
#endif /* USE_MMAP, MSDOS, BSD or SYSV */

#ifdef USE_MMAP
	heap_start = NULL;
#else
	heap_end = sbrk(0);
	i = (int)heap_end & (LISP_PAGESIZE - 1);
	if (i)
	  sbrk(LISP_PAGESIZE - i);
	heap_end = heap_start = data_end = sbrk(0);
#endif
	cl_resize_hole(INIT_HOLEPAGE);
	for (i = 0;  i < MAXPAGE;  i++)
		type_map[i] = (char)t_other;

/*	Initialization must be done in increasing size order:	*/
	init_tm(t_shortfloat, "FSHORT-FLOAT", /* 8 */
		sizeof(struct shortfloat_struct), 1);
	init_tm(t_cons, ".CONS", sizeof(struct cons), 384); /* 12 */
	init_tm(t_longfloat, "LLONG-FLOAT", /* 16 */
		sizeof(struct longfloat_struct), 1);
	init_tm(t_bytecodes, "bBYTECODES", sizeof(struct bytecodes), 64);
	init_tm(t_string, "\"STRING", sizeof(struct string), 64); /* 20 */
	init_tm(t_array, "aARRAY", sizeof(struct array), 64); /* 24 */
	init_tm(t_pathname, "pPATHNAME", sizeof(struct pathname), 1); /* 28 */
	init_tm(t_symbol, "|SYMBOL", sizeof(struct symbol), 64); /* 32 */
	init_tm(t_package, ":PACKAGE", sizeof(struct package), 1); /* 36 */
	init_tm(t_codeblock, "#CODEBLOCK", sizeof(struct codeblock), 1);
	init_tm(t_bignum, "BBIGNUM", sizeof(struct bignum), 16);
	init_tm(t_ratio, "RRATIO", sizeof(struct ratio), 1);
	init_tm(t_complex, "CCOMPLEX", sizeof(struct complex), 1);
	init_tm(t_hashtable, "hHASH-TABLE", sizeof(struct hashtable), 1);
	init_tm(t_vector, "vVECTOR", sizeof(struct vector), 2);
	init_tm(t_bitvector, "bBIT-VECTOR", sizeof(struct vector), 1);
	init_tm(t_stream, "sSTREAM", sizeof(struct stream), 1);
	init_tm(t_random, "$RANDOM-STATE", sizeof(struct random), 1);
	init_tm(t_readtable, "rREADTABLE", sizeof(struct readtable), 1);
	init_tm(t_cfun, "fCFUN", sizeof(struct cfun), 32);
	init_tm(t_cclosure, "cCCLOSURE", sizeof(struct cclosure), 1);
#ifndef CLOS
	init_tm(t_structure, "SSTRUCTURE", sizeof(struct structure), 32);
#else
	init_tm(t_instance, "IINSTANCE", sizeof(struct instance), 32);
	init_tm(t_gfun, "GGFUN", sizeof(struct gfun), 32);
#endif /* CLOS */
#ifdef THREADS
	init_tm(t_cont, "?CONT", sizeof(struct cont), 2);
	init_tm(t_thread, "tTHREAD", sizeof(struct thread), 2);
#endif /* THREADS */

	ncb = 0;
	ncbpage = 0;
#ifdef THREADS
	maxcbpage = 2048;
#else
	maxcbpage = 512;
#endif /* THREADS */

#ifdef NEED_MALLOC
	malloc_list = Cnil;
	register_root(&malloc_list);
#endif
}

static int
t_from_type(cl_object type)
{  int t;

   type = cl_string(type);
   for (t = (int)t_start ; t < (int)t_end ; t++) {
     struct typemanager *tm = &tm_table[t];
     if (tm->tm_name &&
	 strncmp((tm->tm_name)+1, type->string.self, type->string.fillp) == 0)
       return(t);
   }
   FEerror("Unrecognized type", 0);
}

@(defun si::allocate (type qty &optional (now Cnil))
	struct typemanager *tm;
	cl_ptr pp;
	cl_index i;
@
	tm = tm_of(t_from_type(type));
	i = fixnnint(qty);
	if (tm->tm_npage > i) i = tm->tm_npage;
	tm->tm_maxpage = i;
	if (now == Cnil || tm->tm_maxpage <= tm->tm_npage)
	  @(return Ct)
	if (available_pages() < tm->tm_maxpage - tm->tm_npage ||
	    (pp = alloc_page(tm->tm_maxpage - tm->tm_npage)) == NULL)
	  FEerror("Can't allocate ~D pages for ~A.", 2, type,
		  make_simple_string(tm->tm_name+1));
	for (;  tm->tm_npage < tm->tm_maxpage;  pp += LISP_PAGESIZE)
	  add_page_to_freelist(pp, tm);
	@(return Ct)
@)

@(defun si::maximum-allocatable-pages (type)
@
	@(return MAKE_FIXNUM(tm_of(t_from_type(type))->tm_maxpage))
@)

@(defun si::allocated-pages (type)
@
	@(return MAKE_FIXNUM(tm_of(t_from_type(type))->tm_npage))
@)

@(defun si::allocate-contiguous-pages (qty &optional (now Cnil))
	cl_index i, m;
	cl_ptr p;
@
	i = fixnnint(qty);
	if (ncbpage > i)
	  FEerror("Can't set the limit for contiguous blocks to ~D,~%\
since ~D pages are already allocated.",
			2, qty, MAKE_FIXNUM(ncbpage));
	maxcbpage = i;
	if (Null(now))
	  @(return Ct)
	m = maxcbpage - ncbpage;
	if (available_pages() < m || (p = alloc_page(m)) == NULL)
		FEerror("Can't allocate ~D pages for contiguous blocks.",
			1, qty);
	for (i = 0;  i < m;  i++)
		type_map[page(p + LISP_PAGESIZE*i)] = (char)t_contiguous;
	ncbpage += m;
	cl_dealloc(p, LISP_PAGESIZE*m);
	@(return Ct)
@)

@(defun si::allocated-contiguous-pages ()
@
	@(return MAKE_FIXNUM(ncbpage))
@)

@(defun si::maximum-contiguous-pages ()
@
	@(return MAKE_FIXNUM(maxcbpage))
@)

@(defun si::get_hole_size ()
@
	@(return MAKE_FIXNUM(new_holepage))
@)

@(defun si::set_hole_size (size)
	cl_index i;
@
	i = fixnnint(size);
	if (i == 0 || i > available_pages() + new_holepage)
	  FEerror("Illegal value for the hole size.", 0);
	new_holepage = i;
	@(return size)
@)

@(defun si::ignore_maximum_pages (&optional (flag OBJNULL))
@
	if (flag == OBJNULL)
		@(return (ignore_maximum_pages? Ct : Cnil))
	ignore_maximum_pages = Null(flag);
	@(return flag)
@)

void
init_alloc_function(void)
{
	ignore_maximum_pages = TRUE;
}

#ifdef NEED_MALLOC
/*
	UNIX malloc simulator.

	Used by
		getwd, popen, etc.
*/

#undef malloc
#undef calloc
#undef free
#undef cfree
#undef realloc

void *
malloc(size_t size)
{
  cl_object x;

  if (!GC_enabled() && !alloc_initialized)
    init_alloc();

  x = alloc_simple_string(size-1);
  x->string.self = (char *)cl_alloc(size);
  malloc_list = make_cons(x, malloc_list);
  return(x->string.self);
}

void
free(void *ptr)
{
  cl_object *p;

  if (ptr) {
    for (p = &malloc_list;  !endp(*p);  p = &(CDR((*p))))
      if ((CAR((*p)))->string.self == ptr) {
	cl_dealloc(CAR((*p))->string.self, CAR((*p))->string.dim+1);
	CAR((*p))->string.self = NULL;
	*p = CDR((*p));
	return;
      }
    FEerror("free(3) error.", 0);
  }
}

void *
realloc(void *ptr, size_t size)
{
  cl_object x;
  size_t i, j;

  if (ptr == NULL)
    return malloc(size);
  for (x = malloc_list;  !endp(x);  x = CDR(x))
    if (CAR(x)->string.self == ptr) {
      x = CAR(x);
      if (x->string.dim >= size) {
	x->string.fillp = size;
	return(ptr);
      } else {
	j = x->string.dim;
	x->string.self = (char *)cl_alloc(size);
	x->string.fillp = x->string.dim = size;
	memcpy(x->string.self, ptr, j);
	cl_dealloc(ptr, j);
	return(x->string.self);
      }
    }
  FEerror("realloc(3) error.", 0);
}

void *
calloc(size_t nelem, size_t elsize)
{
  char *ptr;
  size_t i = nelem*elsize;
  ptr = malloc(i);
  memset(ptr, 0 , i);
  return(ptr);
}

void cfree(void *ptr)
{
  free(ptr);
}

/* make f allocate enough extra, so that we can round
   up, the address given to an even multiple.   Special
   case of size == 0 , in which case we just want an aligned
   number in the address range
   */

#define ALLOC_ALIGNED(f, size, align) \
	((align) <= 4 ? (int)(f)(size) : \
	   ((align) * (((unsigned)(f)(size + (size ? (align) - 1 : 0)) + (align) - 1)/(align))))

void *
memalign(size_t align, size_t size)
{ cl_object x = alloc_simple_string(size);
  malloc_list = make_cons(x, malloc_list);
  return x->string.self;
}

# ifdef WANT_VALLOC
char *
valloc(size_t size)
{ return memalign(getpagesize(), size);}
# endif /* WANT_VALLOC */
#endif /* NEED_MALLOC */
