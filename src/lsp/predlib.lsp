;;;;  Copyright (c) 1984, Taiichi Yuasa and Masami Hagiya.
;;;;  Copyright (c) 1990, Giuseppe Attardi.
;;;;
;;;;    This program is free software; you can redistribute it and/or
;;;;    modify it under the terms of the GNU Library General Public
;;;;    License as published by the Free Software Foundation; either
;;;;    version 2 of the License, or (at your option) any later version.
;;;;
;;;;    See file '../Copyright' for full details.

;;;;                              predicate routines


(in-package "CL")
(export '(DEFTYPE TYPEP SUBTYPEP COERCE #+clos subclassp))

(in-package "SYSTEM")

;;; DEFTYPE macro.
(defmacro deftype (name lambda-list &rest body)
  "Syntax: (deftype name lambda-list {decl | doc}* {form}*)
Defines a new type-specifier abbreviation in terms of an 'expansion' function
	(lambda lambda-list1 {DECL}* {FORM}*)
where LAMBDA-LIST1 is identical to LAMBDA-LIST except that all optional
parameters with no default value specified in LAMBDA-LIST defaults to the
symbol '*', but not to NIL.  When the type system of ECL encounters a type
specifier (NAME arg1 ... argn), it calls the expansion function with the
arguments ARG1 ... ARGn, and uses the returned value instead of the original
type specifier.  When the symbol NAME is used as a type specifier, the
expansion function is called with no argument.
The doc-string DOC, if supplied, is saved as a TYPE doc and can be retrieved
by (documentation 'NAME 'type)."
  (multiple-value-bind (body doc)
      (remove-documentation body)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
          (setf (get ',name 'DEFTYPE-FORM)
	   '(DEFTYPE ,name ,lambda-list ,@body))
          (setf (get ',name 'DEFTYPE-DEFINITION)
	   #'(LAMBDA ,lambda-list ,@body))
	  ,@(si::expand-set-documentation name 'type doc)
          ',name)))


;;; Some DEFTYPE definitions.
(deftype boolean ()
  "A BOOLEAN is an object which is either NIL or T."
  `(member nil t))

(deftype fixnum ()
  "A FIXNUM is an integer between MOST-NEGATIVE-FIXNUM (= - 2^29 in ECL) and
MOST-POSITIVE-FIXNUM (= 2^29 - 1 in ECL) inclusive.  Other integers are
bignums."
  `(INTEGER #.most-negative-fixnum #.most-positive-fixnum))

(deftype byte8 () `(INTEGER 0 255))
(deftype integer8 () `(INTEGER -128 127))

(deftype real (&rest foo) '(OR RATIONAL FLOAT))
(deftype bit ()
  "A BIT is either integer 0 or 1."
  '(INTEGER 0 1))

(deftype mod (n)
  `(INTEGER 0 ,(1- n)))

(deftype compiled-function () 'FUNCTION)

(deftype signed-byte (&optional s)
  "As a type specifier, (SIGNED-BYTE n) specifies those integers that can be
represented with N bits in 2's complement representation."
  (if (or (null s) (eq s '*))
      '(INTEGER * *)
      `(INTEGER ,(- (expt 2 (1- s))) ,(1- (expt 2 (1- s))))))

(deftype unsigned-byte (&optional s)
  "As a type specifier, (UNSIGNED-BYTE n) specifies non-negative integers that
can be represented with N bits."
  (if (or (null s) (eq s '*))
      '(INTEGER 0 *)
      `(INTEGER 0 ,(1- (expt 2 s)))))

#+clos
(deftype structure () 'STRUCTURE-OBJECT)
(deftype sequence () '(OR CONS NULL (ARRAY * (*))))
(deftype list ()
  "As a type specifier, LIST is used to specify the type consisting of NIL and
cons objects.  In our ordinary life with Lisp, however, a list is either NIL
or a cons whose cdr is a list, and is notated by its elements surrounded with
parentheses.
The backquote macro is sometimes useful to construct a complicated list
structure.  When evaluating `(...)
	,form embeds the value of FORM,
	,@form and ,.form embed all elements of the list value of FORM,
	and other things embed itself
into the structure at their position.  For example,
	`(a b ,c d e) expands to (list* 'a 'b c '(d e))
	`(a b ,@c d e) expands to (list* 'a 'b (append c '(d e)))
	`(a b ,.c d e) expands to (list* 'a 'b (nconc c '(d e)))"
  '(OR CONS NULL))

(deftype atom ()
  "An ATOM is an object that is not a CONS."
  '(NOT CONS))
;(deftype null () '(MEMBER NIL))

(deftype vector (&optional (element-type '*) (size '*))
  "A vector is a one-dimensional array.  Strings and bit-vectors are kinds of
vectors.  Other vectors are called general vectors and are notated as
	#(elem ... elem)
Some vectors may be displaced to another array, may have a fill-pointer, or
may be adjustable.  Other vectors are called simple-vectors."
  `(array ,element-type (,size)))

(deftype string (&optional size)
  "A string is a vector of characters.  A string is notated by surrounding the
characters with double quotes.  Some strings may be displaced to another
string, may have a fill-pointer, or may be adjustable.  Other strings are
called simple-strings."
  (if size `(array character ,size) '(array character (*))))

(deftype base-string (&optional size)
  (if size `(array base-char ,size) '(array base-char (*))))
(deftype bit-vector (&optional size)
  (if size `(array bit (,size)) '(array bit (*))))

(deftype simple-vector (&optional size)
  "A simple-vector is a vector that is not displaced to another array, has no
fill-pointer, and is not adjustable."
  (if size `(simple-array t (,size)) '(simple-array t (*))))

(deftype simple-string (&optional size)
  "A simple-string is a string that is not displaced to another array, has no
fill-pointer, and is not adjustable."
  (if size `(simple-array character (,size)) '(simple-array character (*))))

(deftype simple-base-string (&optional size)
  (if size `(simple-array base-char ,size) '(simple-array base-char (*))))

(deftype simple-bit-vector (&optional size)
  "A simple-bit-vector is a bit-vector that is not displaced to another array,
has no fill-pointer, and is not adjustable."
  (if size `(simple-array bit (,size)) '(simple-array bit (*))))

(defun simple-array-p (x)
  (and (arrayp x)
       (not (adjustable-array-p x))
       (not (array-has-fill-pointer-p x))
       (not (sys:displaced-array-p x))))


(dolist (l '((NULL . NULL)
	     (SYMBOL . SYMBOLP)
	     (KEYWORD . KEYWORDP)
	     (ATOM . ATOM)
	     (CONS . CONSP)
	     (LIST . LISTP)
	     (NUMBER . NUMBERP)
	     (CHARACTER . CHARACTERP)
	     (BASE-CHAR . CHARACTERP)
	     (PACKAGE . PACKAGEP)
	     (STREAM . STREAMP)
	     (PATHNAME . PATHNAMEP)
	     (LOGICAL-PATHNAME . LOGICAL-PATHNAME-P)
	     (READTABLE . READTABLEP)
	     (HASH-TABLE . HASH-TABLE-P)
	     (RANDOM-STATE . RANDOM-STATE-P)
	     (STRUCTURE . SYS:STRUCTUREP)
	     (FUNCTION . FUNCTIONP)
	     (COMPILED-FUNCTION . COMPILED-FUNCTION-P)
	     (DISPATCH-FUNCTION . DISPATCH-FUNCTION-P)
	     (COMMON . COMMONP)
	     (REAL . REALP)
	     ))
  (setf (get (car l) 'TYPE-PREDICATE) (cdr l)))


(defun type-for-array (element-type)
  (case element-type
        ((t nil) t)
        ((base-char standard-char extended-char character) 'base-char)
	(t (dolist (v '(BIT BASE-CHAR BYTE8 INTEGER8
			(SIGNED-BYTE 32) (UNSIGNED-BYTE 32)
			SHORT-FLOAT LONG-FLOAT) T)
	     (when (subtypep element-type v)
	       (return (if (symbolp v) v 'FIXNUM)))))))

;;; TYPEP predicate.
(defun typep (object type &aux tp i c)
  "Args: (object type)
Returns T if X belongs to TYPE; NIL otherwise."
  (cond ((symbolp type)
	 (let ((f (get type 'TYPE-PREDICATE)))
	   (cond (f (return-from typep (funcall f object)))
		 ((eq (type-of object) type) (return-from typep t))
		 (t (setq tp type i nil)))))
	((consp type)
	 (setq tp (car type) i (cdr type)))
	#+clos
	((sys:instancep type)
	 (return-from typep (subclassp (class-of object) type)))
	(t
	 (error "typep: not a valid type specifier ~A for ~A" type object)))
  (case tp
    (MEMBER (and (member object i) t))
    (NOT (not (typep object (car i))))
    (OR (dolist (e i)
	  (when (typep object e) (return t))))
    (AND (dolist (e i t)
	   (unless (typep object e) (return nil))))
    (SATISFIES (funcall (car i) object))
    ((T) t)
    ((NIL) nil)
    (FIXNUM (eq (type-of object) 'FIXNUM))
    (BIGNUM (eq (type-of object) 'BIGNUM))
    (RATIO (eq (type-of object) 'RATIO))
    (STANDARD-CHAR
     (and (characterp object) (standard-char-p object)))
    (INTEGER
     (and (integerp object) (in-interval-p object i)))
    (RATIONAL
     (and (rationalp object) (in-interval-p object i)))
    (FLOAT
     (and (floatp object) (in-interval-p object i)))
    (REAL
     (and (or (rationalp object) (floatp object)) (in-interval-p object i)))
    ((SINGLE-FLOAT SHORT-FLOAT)
     (and (eq (type-of object) 'SHORT-FLOAT) (in-interval-p object i)))
    ((DOUBLE-FLOAT LONG-FLOAT)
     (and (eq (type-of object) 'LONG-FLOAT) (in-interval-p object i)))
    (COMPLEX
     (and (complexp object)
          (or (null i)
	      (and (typep (realpart object) (car i))
		   ;;wfs--should only have to check one.
		   ;;Illegal to mix real and imaginary types!
		   (typep (imagpart object) (car i))))
	   ))
    (SEQUENCE (or (listp object) (vectorp object)))
    (STRING
     (and (stringp object)
          (or (null i) (match-dimensions (array-dimensions object) i))))
    (BIT-VECTOR
     (and (bit-vector-p object)
          (or (null i) (match-dimensions (array-dimensions object) i))))
    (SIMPLE-STRING
     (and (simple-string-p object)
          (or (null i) (match-dimensions (array-dimensions object) i))))
    (SIMPLE-BIT-VECTOR
     (and (simple-bit-vector-p object)
          (or (null i) (match-dimensions (array-dimensions object) i))))
    (SIMPLE-VECTOR
     (and (simple-vector-p object)
          (or (null i) (match-dimensions (array-dimensions object) i))))
    (SIMPLE-ARRAY
     (and (simple-array-p object)
          (or (endp i) (eq (car i) '*)
	      ;; (car i) needs expansion
	      (eq (array-element-type object)
		  (type-for-array (car i))))
          (or (endp (cdr i)) (eq (second i) '*)
              (match-dimensions (array-dimensions object) (second i)))))
    (ARRAY
     (and (arrayp object)
          (or (endp i) (eq (car i) '*)
              ;; Or the element type of object should be EQUAL to (car i).
              ;; Is this too strict?
              (eq (array-element-type object)
		  (type-for-array (car i))))
          (or (endp (cdr i)) (eq (second i) '*)
              (match-dimensions (array-dimensions object) (second i)))))
    (t
     (cond
           ((get tp 'DEFTYPE-DEFINITION)
            (typep object
                   (apply (get tp 'DEFTYPE-DEFINITION) i)))
           #+clos
	   ((setq c (find-class type nil))
	    ;; Follow the inheritance chain
	    (subclassp (class-of object) c))
	   #-clos
	   ((get tp 'IS-A-STRUCTURE)
            (when (sys:structurep object)
	      ;; Follow the chain of structure-include.
	      (do ((stp (sys:structure-name object)
			(get stp 'STRUCTURE-INCLUDE)))
		  ((eq tp stp) t)
		(when (null (get stp 'STRUCTURE-INCLUDE))
		  (return nil)))))
	   (t (error "typep: not a valid type specifier ~A for ~A" type object))))))

#+clos
(defun subclassp (low high)
  (or (eq low high)
      (dolist (class (sys:instance-ref low 1)) ; (class-superiors low)
	(when (subclassp class high) (return t)))))
#+clos
(defun clos::classp (foo)
  (declare (ignore foo))
  nil)

;;; NORMALIZE-TYPE normalizes the type using the DEFTYPE definitions.
;;; The result is a pair of values
;;;  VALUE-1 = normalized type name or object
;;;  VALUE-2 = normalized type arguments or nil
(defun normalize-type (type &aux tp i fd)
  ;; Loops until the car of type has no DEFTYPE definition.
  (cond ((symbolp type)
	 (if (setq fd (get type 'DEFTYPE-DEFINITION))
	   (normalize-type (funcall fd))
	   (values type nil)))
	#+clos
	((clos::classp type) (values type nil))
	((atom type)
	 (error "normalize-type: bogus type specifier ~A" type))
	((progn
	   (setq tp (car type) i (cdr type))
	   (setq fd (get tp 'DEFTYPE-DEFINITION)))
	 (normalize-type (apply fd i)))
	((and (eq tp 'INTEGER) (consp (cadr i)))
	 (values tp (list (car i) (1- (caadr i)))))
	(t (values tp i))))

;;; KNOWN-TYPE-P answers if the given type is a known base type.
;;; The type MUST be normalized.
(defun known-type-p (type)
  (declare (si::c-local))
  (cond #+clos
	((sys::instancep type) t)
	((not (symbolp type)) nil)
	((or (member type
                  '(T NIL NULL SYMBOL KEYWORD CONS LIST
                    NUMBER INTEGER BIGNUM RATIONAL RATIO FLOAT
                    SHORT-FLOAT SINGLE-FLOAT DOUBLE-FLOAT LONG-FLOAT COMPLEX
                    CHARACTER BASE-CHAR STANDARD-CHAR EXTENDED-CHAR
                    PACKAGE STREAM PATHNAME READTABLE HASH-TABLE RANDOM-STATE
                    #-clos STRUCTURE ARRAY SIMPLE-ARRAY FUNCTION FUNCTION
		    REAL))
	     #+clos
	     (find-class type nil)
	     #-clos
	     (get type 'IS-A-STRUCTURE))
	 t)
	(t nil)))

;;; SUBTYPEP predicate.
(defun subtypep (type1 type2 &aux t1 t2 i1 i2 ntp1 ntp2 c1 c2)
  "Args: (type1 type2)
Returns T if TYPE1 is a subtype of TYPE2; NIL otherwise.  If this is not
determined, then returns NIL as the first and second values.  Otherwise, the
second value is T."
    (when (equal type1 type2)
      (return-from subtypep (values t t)))
    (multiple-value-setq (t1 i1) (normalize-type type1))
    (case t1
      (MEMBER (dolist (e i1)
		(unless (typep e type2) (return-from subtypep (values nil t))))
	      (return-from subtypep (values t t)))
      (OR (dolist (tt i1)
	    (multiple-value-bind (tv flag) (subtypep tt type2)
	      (unless tv (return-from subtypep (values tv flag)))))
	  (return-from subtypep (values t t)))
      (AND (dolist (tt i1)
	     (let ((tv (subtypep tt type2)))
	       (when tv (return-from subtypep (values t t)))))
	   (return-from subtypep (values nil nil)))
      (NOT (multiple-value-bind (tv flag) (subtypep (car i1) type2)
	     (return-from subtypep (values (and flag (not tv)) flag)))))
    (multiple-value-setq (t2 i2) (normalize-type type2))
    (when (and (equal t1 t2) (equal i1 i2))
      (return-from subtypep (values t t)))
    (case t2
      (MEMBER (return-from subtypep (values nil nil)))
      (OR (dolist (tt i2)
	    (let ((tv (subtypep type1 tt)))
	      (when tv (return-from subtypep (values t t)))))
	  (return-from subtypep (values nil nil)))
      (AND (dolist (tt i2)
	     (multiple-value-bind (tv flag) (subtypep type1 tt)
	       (unless tv (return-from subtypep (values tv flag)))))
	   (return-from subtypep (values t t)))
      (NOT (multiple-value-bind (tv flag) (subtypep type1 (car i2))
	     (return-from subtypep (values (not tv) flag)))))
    (setq ntp1 (known-type-p t1) ntp2 (known-type-p t2))
    (flet ((find-the-class (x)
	     #-clos nil
	     #+clos
	     ;; these are the build-in classes of CLOS:
	     (cond ((sys::instancep x) x)
		   ((member x '(ARRAY CONS STRING
				BIT-VECTOR CHARACTER NUMBER COMPLEX FLOAT
				RATIONAL INTEGER RATIO SYMBOL KEYWORD)
			    :test #'eq)
		    nil)
		   ((symbolp x) (find-class x nil))
		   (t nil))))
      (cond ((or (eq t1 'NIL) (eq t2 'T) (eq t2 'COMMON)) (values t t))
	    ((eq t2 'NIL) (values nil ntp1))
	    ((eq t1 'T) (values nil ntp2))
	    ((eq t1 'COMMON) (values nil ntp2))
	    ((eq t2 'SYMBOL)
	     (if (member t1 '(SYMBOL KEYWORD NULL) :test #'eq)
		 (values t t)
		 (values nil ntp1)))
	    ((eq t2 'KEYWORD)
	     (if (eq t1 'KEYWORD) (values t t) (values nil ntp1)))
	    ((eq t2 'NULL)
	     (if (eq t1 'NULL) (values t t) (values nil ntp1)))
	    ((eq t2 'NUMBER)
	     (cond ((member t1 '(BIGNUM INTEGER RATIO RATIONAL FLOAT
				 SHORT-FLOAT SINGLE-FLOAT DOUBLE-FLOAT
				 LONG-FLOAT COMPLEX NUMBER
				 REAL)
			    :test #'eq)
		    (values t t))
		   (t (values nil ntp1))))
	    ((eq t1 'NUMBER) (values nil ntp2))
	    #-clos
	    ((eq t2 'STRUCTURE)
	     (if (or (eq t1 'STRUCTURE)
		     (get t1 'IS-A-STRUCTURE))
		 (values t t)
		 (values nil ntp1)))
	    #-clos
	    ((eq t1 'STRUCTURE) (values nil ntp2))
	    #-clos
	    ((get t1 'IS-A-STRUCTURE)
	     (if (get t2 'IS-A-STRUCTURE)
		 (do ((tp1 t1 (get tp1 'STRUCTURE-INCLUDE)) (tp2 t2))
		     ((null tp1) (values nil t))
		   (when (eq tp1 tp2) (return (values t t))))
		 (values nil ntp2)))
	    #-clos
	    ((get t2 'IS-A-STRUCTURE) (values nil ntp1))
	    #+clos
	    ((setq c1 (find-the-class t1))
	     (if (setq c2 (find-the-class t2))
		 (values (subclassp c1 c2) t)
		 (values nil ntp1)))
	    #+clos
	    ((find-the-class t2) (values nil ntp1))
	    (t
	     (case t1
	       (BIGNUM
		(case t2
		  (bignum (values t t))
		  ((integer rational)
		   (if (sub-interval-p '(* *) i2)
		       (values t t)
		       (values nil t)))
		  (t (values nil ntp2))))
	       (RATIO
		(case t2
		  (ratio (values t t))
		  (rational
		   (if (sub-interval-p '(* *) i2) (values t t) (values nil t)))
		  (t (values nil ntp2))))
	       (STANDARD-CHAR
		(if (member t2 '(STANDARD-CHAR BASE-CHAR CHARACTER)
			    :test #'eq)
		    (values t t)
		    (values nil ntp2)))
	       (BASE-CHAR
		(if (member t2 '(BASE-CHAR CHARACTER) :test #'eq)
		    (values t t)
		    (values nil ntp2)))
	       (EXTENDED-CHAR
		(if (eq t2 'CHARACTER)
		    (values t t)
		    (values nil ntp2)))
	       (INTEGER
		(if (member t2 '(INTEGER RATIONAL) :test #'eq)
		    (values (sub-interval-p i1 i2) t)
		    (values nil ntp2)))
	       (RATIONAL
		(if (eq t2 'RATIONAL)
		    (values (sub-interval-p i1 i2) t)
		    (values nil ntp2)))
	       (FLOAT
		(if (eq t2 'FLOAT)
		    (values (sub-interval-p i1 i2) t)
		    (values nil ntp2)))
	       ((SINGLE-FLOAT SHORT-FLOAT)
		(if (member t2 '(SHORT-FLOAT FLOAT) :test #'eq)
		    (values (sub-interval-p i1 i2) t)
		    (values nil ntp2)))
	       ((DOUBLE-FLOAT LONG-FLOAT)
		(if (member t2 '(SINGLE-FLOAT DOUBLE-FLOAT LONG-FLOAT FLOAT)
			    :test #'eq)
		    (values (sub-interval-p i1 i2) t)
		    (values nil ntp2)))
	       (COMPLEX
		(if (eq t2 'COMPLEX)
		    (subtypep (or (car i1) t) (or (car i2) t))
		    (values nil ntp2)))
	       (LOGICAL-PATHNAME
		(if (eq t2 'PATHNAME)
		    (values t t)
		    (values nil ntp2)))
	       (SIMPLE-ARRAY
		(cond ((or (eq t2 'SIMPLE-ARRAY) (eq t2 'ARRAY))
		       (if (or (endp i1) (eq (car i1) '*))
			   (unless (or (endp i2) (eq (car i2) '*))
			     (return-from subtypep (values nil t)))
			   (unless (or (endp i2) (eq (car i2) '*))
			     (unless (eq (type-for-array (car i1))
					 (type-for-array (car i2)))
			       ;; Unless the element type matches,
			       ;;  return NIL T.
			       ;; Is this too strict?
			       (return-from subtypep
				 (values nil t)))))
		       (when (or (endp (cdr i1)) (eq (second i1) '*))
			 (if (or (endp (cdr i2)) (eq (second i2) '*))
			     (return-from subtypep (values t t))
			     (return-from subtypep (values nil t))))
		       (when (or (endp (cdr i2)) (eq (second i2) '*))
			 (return-from subtypep (values t t)))
		       (values (match-dimensions (second i1) (second i2)) t))
		      (t (values nil ntp2))))
	       (ARRAY
		(cond ((eq t2 'ARRAY)
		       (if (or (endp i1) (eq (car i1) '*))
			   (unless (or (endp i2) (eq (car i2) '*))
			     (return-from subtypep (values nil t)))
			   (unless (or (endp i2) (eq (car i2) '*))
			     (unless (eq (type-for-array (car i1))
					 (type-for-array (car i2)))
			       (return-from subtypep
				 (values nil t)))))
		       (when (or (endp (cdr i1)) (eq (second i1) '*))
			 (if (or (endp (cdr i2)) (eq (second i2) '*))
			     (return-from subtypep (values t t))
			     (return-from subtypep (values nil t))))
		       (when (or (endp (cdr i2)) (eq (second i2) '*))
			 (return-from subtypep (values t t)))
		       (values (match-dimensions (second i1) (second i2)) t))
		      (t (values nil ntp2))))
	       (t (if ntp1 (values (eq t1 t2) t) (values nil nil))))))))


(defun sub-interval-p (i1 i2)
  (let* (low1 high1 low2 high2)
    (if (endp i1)
        (setq low1 '* high1 '*)
        (if (endp (cdr i1))
            (setq low1 (car i1) high1 '*)
            (setq low1 (car i1) high1 (second i1))))
    (if (endp i2)
        (setq low2 '* high2 '*)
        (if (endp (cdr i2))
            (setq low2 (car i2) high2 '*)
            (setq low2 (car i2) high2 (second i2))))
    (cond ((eq low1 '*)
	   (unless (eq low2 '*)
	           (return-from sub-interval-p nil)))
          ((eq low2 '*))
	  ((consp low1)
	   (if (consp low2)
	       (when (< (car low1) (car low2))
		     (return-from sub-interval-p nil))
	       (when (< (car low1) low2)
		     (return-from sub-interval-p nil))))
	  ((if (consp low2)
	       (when (<= low1 (car low2))
		     (return-from sub-interval-p nil))
	       (when (< low1 low2)
		     (return-from sub-interval-p nil)))))
    (cond ((eq high1 '*)
	   (unless (eq high2 '*)
	           (return-from sub-interval-p nil)))
          ((eq high2 '*))
	  ((consp high1)
	   (if (consp high2)
	       (when (> (car high1) (car high2))
		     (return-from sub-interval-p nil))
	       (when (> (car high1) high2)
		     (return-from sub-interval-p nil))))
	  ((if (consp high2)
	       (when (>= high1 (car high2))
		     (return-from sub-interval-p nil))
	       (when (> high1 high2)
		     (return-from sub-interval-p nil)))))
    (return-from sub-interval-p t)))

(defun in-interval-p (x interval)
  (declare (si::c-local))
  (let* (low high)
    (if (endp interval)
        (setq low '* high '*)
        (if (endp (cdr interval))
            (setq low (car interval) high '*)
            (setq low (car interval) high (second interval))))
    (cond ((eq low '*))
          ((consp low)
           (when (<= x (car low)) (return-from in-interval-p nil)))
          ((when (< x low) (return-from in-interval-p nil))))
    (cond ((eq high '*))
          ((consp high)
           (when (>= x (car high)) (return-from in-interval-p nil)))
          ((when (> x high) (return-from in-interval-p nil))))
    (return-from in-interval-p t)))

(defun match-dimensions (dim pat)
  (declare (si::c-local))
  (if (null dim)
      (null pat)
      (and (or (eq (car pat) '*)
	       (eq (car dim) (car pat)))
	   (match-dimensions (cdr dim) (cdr pat)))))



;;; COERCE function.
(defun coerce (object type &aux name args)
  "Args: (x type)
Coerces X to an object of the specified type, if possible.  Signals an error
if not possible."
  (when (typep object type)
        ;; Just return as it is.
        (return-from coerce object))
  (when (eq type 'LIST)
     (do ((l nil (cons (elt object i) l))
          (i (1- (length object)) (1- i)))
         ((< i 0) (return-from coerce l))
       (declare (fixnum i))))
  (multiple-value-setq (name args) (normalize-type type))
  (case name
    (FUNCTION
     (coerce-to-function object))
    ((ARRAY SIMPLE-ARRAY)
     (unless (or (endp args)
                 (endp (cdr args))
                 (atom (cadr args))
                 (endp (cdadr args)))
             (error "Cannot coerce to a multi-dimensional array."))
     (do* ((l (length object))
	   (seq (make-sequence type l))
	   (i 0 (1+ i)))
	  ((>= i l) seq)
       (declare (fixnum i l))
       (setf (elt seq i) (coerce (elt object i)
				 (if (eq (car args) '*)
				     'T
				     (car args))))))
    ((CHARACTER BASE-CHAR) (character object))
    (FLOAT (float object))
    ((SINGLE-FLOAT SHORT-FLOAT) (float object 0.0S0))
    ((DOUBLE-FLOAT LONG-FLOAT) (float object 0.0L0))
    (COMPLEX
     (if (or (null args) (null (car args)) (eq (car args) '*))
         (complex (realpart object) (imagpart object))
         (complex (coerce (realpart object) (car args))
                  (coerce (imagpart object) (car args)))))
    (t (error "Cannot coerce ~S to ~S." object type))))
