/*
    unixfsys.c  -- Unix file system interface.
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

#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#ifdef HAVE_PWD_H
#include <pwd.h>
#endif
#include <sys/stat.h>
#include <stdlib.h>
#include "ecl.h"
#include "ecl-inl.h"
#ifdef HAVE_DIRENT_H
#include <dirent.h>
#else
#include <sys/dir.h>
#endif
#ifndef HAVE_MKSTEMP
#include <fcntl.h>
#endif
#ifndef MAXPATHLEN
# ifdef PATH_MAX
#   define MAXPATHLEN PATH_MAX
# else
#   error "Either MAXPATHLEN or PATH_MAX should be defined"
# endif
#endif

/*
 * string_to_pathanme, to be used when s is a real pathname
 */
cl_object
string_to_pathname(char *s)
{
  cl_index e;
  return parse_namestring(s, 0, strlen(s), &e, Cnil);
}

/*
 * Finds current directory by using getcwd() with an adjustable
 * string which grows until it can host the whole path.
 */
static cl_object
current_dir(void) {
	cl_object output;
	const char *ok;
	cl_index size = 128;

	do {
	  output = cl_alloc_adjustable_string(size);
	  ok = getcwd(output->string.self, size);
	  size += 256;
	} while(ok == NULL);
	size = strlen(output->string.self);
	if ((size + 1 /* / */ + 1 /* 0 */) >= output->string.dim) {
	  /* Too large to host the trailing '/' */
	  cl_object other = cl_alloc_adjustable_string(size+2);
	  strcpy(other->string.self, output->string.self);
	  output = other;
	}
	output->string.self[size++] = '/';
	output->string.self[size] = 0;
	output->string.fillp = size;
	return output;
}

/*
 * Using a certain path, guess the type of the object it points to.
 */

static cl_object
file_kind(char *filename, bool follow_links) {
	struct stat buf;
#ifdef HAVE_LSTAT
	if ((follow_links? stat : lstat)(filename, &buf) < 0)
#else
	if (stat(filename, &buf) < 0)
#endif
		return Cnil;
#ifdef HAVE_LSTAT
	if (S_ISLNK(buf.st_mode))
		return @':link';
#endif
	if (S_ISDIR(buf.st_mode))
		return @':directory';
	if (S_ISREG(buf.st_mode))
		return @':file';
	return @':special';
}

cl_object
si_file_kind(cl_object filename, cl_object follow_links) {
	filename = coerce_to_filename(filename);

	@(return file_kind(filename->string.self, !Null(follow_links)))
}

static cl_object
si_follow_symlink(cl_object filename) {
	cl_object output, kind;
	int size = 128, written;

	output = coerce_to_filename(filename);
	kind = file_kind(output->string.self, FALSE);
#ifdef HAVE_LSTAT
	while (kind == @':link') {
		cl_object aux;
		do {
			aux = cl_alloc_adjustable_string(size);
			written = readlink(output->string.self, aux->string.self, size);
			size += 256;
		} while(written == size);
		aux->string.self[written] = '\0';
		output = aux;
		kind = file_kind(output->string.self, FALSE);
		if (kind == @':directory') {
			output->string.self[written++] = '/';
			output->string.self[written] = '\0';
		}
		output->string.fillp = written;
	}
#endif
	if (kind == @':directory' &&
	    output->string.self[output->string.fillp-1] != '/')
		FEerror("Filename ~S actually points to a directory", 1, filename);
	@(return ((kind == Cnil)? Cnil : output))
}


/*
 * Search the actual name of the directory of a pathname,
 * going through links if they exist. Default is
 * current directory
 */
cl_object
cl_truename(cl_object pathname)
{
	cl_object directory, filename;

	/* First we ensure that PATHNAME itself does not point to a symlink. */
	filename = si_follow_symlink(pathname);
	if (filename == Cnil)
		FEerror("truename: file ~S does not exist or cannot be accessed", 1,
			pathname);

	/* Next we process the directory part of the filename, removing all
	 * possible symlinks. To do so, we only have to change to the directory
	 * which contains our file, and come back. SI::CHDIR calls getcwd() which
	 * should return the canonical form of the directory.
	 */
	directory = si_chdir(filename);
	directory = si_chdir(directory);

	@(return merge_pathnames(directory, filename, @':newest'))
}

FILE *
backup_fopen(const char *filename, const char *option)
{
	char backupfilename[MAXPATHLEN];

	strcat(strcpy(backupfilename, filename), ".BAK");
	if (rename(filename, backupfilename))
		FElibc_error("Cannot rename the file ~S to ~S.", 2,
			     filename, backupfilename);
	return fopen(filename, option);
}

int
file_len(FILE *fp)
{
	struct stat filestatus;

	fstat(fileno(fp), &filestatus);
	return(filestatus.st_size);
}

cl_object
cl_rename_file(cl_object oldn, cl_object newn)
{
	cl_object filename, newfilename, old_truename, new_truename;

	/* INV: coerce_to_file_pathname() checks types */
	oldn = coerce_to_file_pathname(oldn);
	newn = coerce_to_file_pathname(newn);
	newn = merge_pathnames(newn, oldn, Cnil);
	old_truename = cl_truename(oldn);
	filename = coerce_to_filename(oldn);
	newfilename = coerce_to_filename(newn);
	if (rename(filename->string.self, newfilename->string.self) < 0)
		FElibc_error("Cannot rename the file ~S to ~S.", 2, oldn, newn);
	new_truename = cl_truename(newn);
	@(return newn old_truename new_truename)
}

cl_object
cl_delete_file(cl_object file)
{
	cl_object filename;

	filename = coerce_to_filename(file);
	if (unlink(filename->string.self) < 0)
		FElibc_error("Cannot delete the file ~S.", 1, file);
	@(return Ct)
}

cl_object
cl_probe_file(cl_object file)
{
	@(return (si_file_kind(file, Ct) != Cnil? cl_truename(file) : Cnil))
}

cl_object
cl_file_write_date(cl_object file)
{
	cl_object filename, time;
	struct stat filestatus;

	filename = coerce_to_filename(file);
	if (stat(filename->string.self, &filestatus) < 0)
	  time = Cnil;
	else
	  time = UTC_time_to_universal_time(filestatus.st_mtime);
	@(return time)
}

cl_object
cl_file_author(cl_object file)
{
	cl_object filename = coerce_to_filename(file);
#ifdef HAVE_PWD_H
	struct stat filestatus;
	struct passwd *pwent;

	if (stat(filename->string.self, &filestatus) < 0)
		FElibc_error("Cannot get the file status of ~S.", 1, file);
	pwent = getpwuid(filestatus.st_uid);
	@(return make_string_copy(pwent->pw_name))
#else
	struct stat filestatus;
	if (stat(filename->string.self, &filestatus) < 0)
		FElibc_error("Cannot get the file status of ~S.", 1, file);
	@(return make_simple_string("UNKNOWN"))
#endif
}

const char *
expand_pathname(const char *name)
{
  const char *path, *p;
  static char pathname[255], *pn;

  if (IS_DIR_SEPARATOR(name[0])) return(name);
  if ((path = getenv("PATH")) == NULL) error("No PATH in environment");
  p = path;
  pn = pathname;
  do {
    if ((*p == '\0') || (*p == PATH_SEPARATOR)) {
      if (pn != pathname) *pn++ = DIR_SEPARATOR; /* on SYSV . is empty */
LAST: strcpy(pn, name);
      if (access(pathname, X_OK) == 0)
	return (pathname);
      pn = pathname;
      if (p[0] == PATH_SEPARATOR && p[1] == '\0') { /* last entry is empty */
	p++;
	goto LAST;
      }
    }
    else
      *pn++ = *p;
  } while (*p++ != '\0');
  return(name);			/* should never occur */
}

cl_object
homedir_pathname(cl_object user)
{
	cl_index i;
	cl_object namestring;
	
	if (Null(user)) {
		extern char *getenv();
		char *h = getenv("HOME");
		namestring = (h == NULL)? make_simple_string("/")
			: make_string_copy(h);
	} else {
#ifdef HAVE_PWD_H
		struct passwd *pwent = NULL;
#endif
		char *p;
		/* This ensures that our string has the right length
		   and it is terminated with a '\0' */
		user = coerce_to_simple_string(cl_string(user));
		p = user->string.self;
		i = user->string.fillp;
		if (i > 0 && *p == '~') {
			p++;
			i--;
		}
		if (i == 0)
			return homedir_pathname(Cnil);
#ifdef HAVE_PWD_H
		pwent = getpwnam(p);
		if (pwent == NULL)
			FEerror("Unknown user ~S.", 1, p);
		namestring = make_string_copy(pwent->pw_dir);
#endif
		FEerror("Unknown user ~S.", 1, p);
	}
	i = namestring->string.fillp;
	if (namestring->string.self[i-1] != '/')
		namestring = si_string_concatenate(2, namestring,
						   make_simple_string("/"));
	return cl_pathname(namestring);
}

@(defun user_homedir_pathname (&optional host)
@
	/* Ignore optional host argument. */
	@(return homedir_pathname(Cnil));
@)

/*
 * Take two C strings and check if the first one matches
 * against the pattern given by the second one. The pattern
 * is that of a Unix shell except for brackets and curly
 * braces
 */
static bool
string_match(const char *s, const char *p) {
	const char *next;
	while (*s) {
	  switch (*p) {
	  case '*':
	    /* Match any group of characters */
	    next = p+1;
	    if (*next != '?') {
	      if (*next == '\\')
		next++;
	      while (*s && *s != *next) s++;
	    }
	    if (string_match(s,next))
	      return TRUE;
	    /* starts back from the '*' */
	    if (!*s)
	      return FALSE;
	    s++;
	    break;
	  case '?':
	    /* Match any character */
	    s++, p++;
	    break;
	  case '\\':
      /* Interpret a pattern character literally.
         Trailing slash is interpreted as a slash. */
	    if (p[1]) p++;
	    if (*s != *p)
	      return FALSE;
	    s++, p++;
	    break;
	  default:
	    if (*s != *p)
	      return FALSE;
	    s++, p++;
	    break;
	  }
	}
	while (*p == '*')
	  p++;
	return (*p == 0);
}

/*
 * list_current_directory() lists the files and directories which are contained
 * in the current working directory (as given by current_dir()). If ONLY_DIR is
 * true, the list is made of only the directories -- a propert which is checked
 * by following the symlinks.
 */
static cl_object
list_current_directory(const char *mask, bool only_dir)
{
	cl_object kind, out = Cnil;
	cl_object *out_cdr = &out;
	char *text;

#if defined(HAVE_DIRENT_H)
	DIR *dir;
	struct dirent *entry;

	dir = opendir("./");
	if (dir == NULL)
		return Cnil;

	while ((entry = readdir(dir))) {
		text = entry->d_name;

#else /* sys/dir.h as in SYSV */
	FILE *fp;
	char iobuffer[BUFSIZ];
	DIRECTORY dir;

	previous_dir = si_chdir(directory);
	fp = fopen("./", OPEN_R);
	if (fp == NULL)
		return Cnil;

	setbuf(fp, iobuffer);
	for (;;) {
		if (fread(&dir, sizeof(DIRECTORY), 1, fp) <= 0)
			break;
		if (dir.d_ino == 0)
			continue;
		text = dir.d_name;
#endif
		if (text[0] == '.' &&
		    (text[1] == '\0' ||
		     (text[1] == '.' && text[2] == '\0')))
			continue;
		if (only_dir && file_kind(text, TRUE) != @':directory')
			continue;
		if (mask && !string_match(text, mask))
			continue;
		*out_cdr = CONS(make_string_copy(text), Cnil);
		out_cdr = &CDR(*out_cdr);
	}
#ifdef HAVE_DIRENT_H
	closedir(dir);
#else
	fclose(fp);
#endif
	return out;
}

/*
 * dir_files() lists all files which are contained in the current directory and
 * which match the masks in PATHNAME. This routine is essentially a wrapper for
 * list_current_directory(), which transforms the list of strings into a list
 * of pathnames. BASEDIR is the truename of the current directory and it is
 * used to build these pathnames.
 */
static cl_object
dir_files(cl_object basedir, cl_object pathname)
{
	cl_object all_files, output = Cnil;
	cl_object mask, name, type;
	int everything;

	name = pathname->pathname.name;
	type = pathname->pathname.type;
	if (name != Cnil || type != Cnil) {
		mask = make_pathname(Cnil, Cnil, Cnil, name, type, @':unspecific');
	} else {
		mask = Cnil;
	}
	all_files = list_current_directory(NULL, FALSE);
	loop_for_in(all_files) {
		char *text = CAR(all_files)->string.self;
		if (file_kind(text, TRUE) == @':directory') {
			if (mask == Cnil) {
				cl_object new = nconc(cl_copy_list(basedir->pathname.directory),
						      CONS(CAR(all_files), Cnil));
				new = make_pathname(basedir->pathname.host,
						    basedir->pathname.device,
						    new, Cnil, Cnil, Cnil);
				output = CONS(new, output);
			}
		} else {
			cl_object new = cl_pathname(CAR(all_files));
			if (mask != Cnil && Null(cl_pathname_match_p(new, mask)))
				continue;
#ifdef HAVE_LSTAT
			if (file_kind(text, FALSE) == @':link')
#else
			if (0)
#endif
				new = cl_truename(CAR(all_files));
			else {
				new->pathname.host = basedir->pathname.host;
				new->pathname.device = basedir->pathname.device;
				new->pathname.directory = basedir->pathname.directory;
			}
			output = CONS(new, output);
		}
	} end_loop_for_in;
	return output;
}

/*
 * dir_recursive() performs the dirty job of DIRECTORY. The routine moves
 * through the filesystem looking for files and directories which match
 * the masks in the arguments PATHNAME and DIRECTORY, collecting them in a
 * list.
 */
static cl_object
dir_recursive(cl_object pathname, cl_object directory)
{
	cl_object item, next_dir, prev_dir = current_dir(), output = Cnil;

	/* There are several possibilities here:
	 *
	 * 1) The list of subdirectories DIRECTORY is empty, and only PATHNAME
	 * remains to be inspected. If there is no file name or type, then
	 * we simply output the truename of the current directory. Otherwise
	 * we have to find a file which corresponds to the description.
	 */
	if (directory == Cnil) {
		prev_dir = cl_pathname(prev_dir);
		return dir_files(prev_dir, pathname);
	}
	/*
	 * 2) We have not yet exhausted the DIRECTORY component of the
	 * pathname. We have to enter some subdirectory, determined by
	 * CAR(DIRECTORY) and scan it.
	 */
	item = CAR(directory);

	if (type_of(item) == t_string || item == @':wild') {
		/*
		 * 2.1) If CAR(DIRECTORY) is a string or :WILD, we have to
		 * enter & scan all subdirectories in our curent directory.
		 */
		next_dir = list_current_directory((item == @':wild')? "*" :
						  (const char *)item->string.self, TRUE);
		loop_for_in(next_dir) {
			char *text = CAR(next_dir)->string.self;
			/* We are unable to move into this directory! */
			if (chdir(text) < 0)
				continue;
			item = dir_recursive(pathname, CDR(directory));
			output = nconc(item, output);
			chdir(prev_dir->string.self);
		} end_loop_for_in;
	} else if (item == @':absolute') {
		/*
		 * 2.2) If CAR(DIRECTORY) is :ABSOLUTE, we have to scan the
		 * root directory.
		 */
		if (chdir("/") < 0)
			return Cnil;
		output = dir_recursive(pathname, CDR(directory));
		chdir(prev_dir->string.self);
	} else if (item == @':relative') {
		/*
		 * 2.3) If CAR(DIRECTORY) is :RELATIVE, we have to scan the
		 * current directory.
		 */
		output = dir_recursive(pathname, CDR(directory));
	} else if (item == @':up') {
		/*
		 * 2.4) If CAR(DIRECTORY) is :UP, we have to scan the directory
		 * which contains this one.
		 */
		if (chdir("..") < 0)
			return Cnil;
		output = dir_recursive(pathname, CDR(directory));
		chdir(prev_dir->string.self);
	} else if (item == @':wild-inferiors') {
		/*
		 * 2.5) If CAR(DIRECTORY) is :WILD-INFERIORS, we have to do
		 * scan all subdirectories from _all_ levels, looking for a
		 * tree that matches the remaining part of DIRECTORY.
		 */
		next_dir = list_current_directory("*", TRUE);
		loop_for_in(next_dir) {
			char *text = CAR(next_dir)->string.self;
			if (chdir(text) < 0)
				continue;
			item = dir_recursive(pathname, directory);
			output = nconc(item, output);
			chdir(prev_dir->string.self);
		} end_loop_for_in;
		output = nconc(output, dir_recursive(pathname, CDR(directory)));
	}
	return output;
}

@(defun directory (mask &key &allow_other_keys)
	cl_object prev_dir = Cnil;
	cl_object output;
@
	CL_UNWIND_PROTECT_BEGIN {
		prev_dir = current_dir();
		mask = coerce_to_file_pathname(mask);
		output = dir_recursive(mask, mask->pathname.directory);
	} CL_UNWIND_PROTECT_EXIT {
		if (prev_dir != Cnil)
			chdir(prev_dir->string.self);
	} CL_UNWIND_PROTECT_END;
	@(return output)
@)

cl_object
si_chdir(cl_object directory)
{
	cl_object previous = current_dir();
	cl_object dir;

	directory = coerce_to_file_pathname(directory);
	for (dir = directory->pathname.directory; !Null(dir); dir = CDR(dir)) {
		cl_object part = CAR(dir);
		if (type_of(part) == t_string) {
			if (chdir(part->string.self) < 0)
				goto ERROR;
		} else if (part == @':absolute') {
			if (chdir("/") < 0) {
				chdir(previous->string.self);
ERROR:				FElibc_error("Can't change the current directory to ~S",
					     1, directory);
			}
		} else if (part == @':relative') {
			/* Nothing to do */
		} else if (part == @':up') {
			if (chdir("..") < 0)
				goto ERROR;
		} else {
			FEerror("~S is not allowed in SI::CHDIR", 1, part);
		}
	}
	@(return previous)
}

cl_object
si_mkdir(cl_object directory, cl_object mode)
{
	cl_object filename;
	cl_index modeint;

	/* INV: coerce_to_filename() checks types */
	filename = coerce_to_filename(directory);
	modeint = fixnnint(mode);
#ifdef mingw32
	if (mkdir(filename->string.self) < 0)
#else
	if (mkdir(filename->string.self, modeint) < 0)
#endif
		FElibc_error("Could not create directory ~S", 1, filename);
	@(return filename)
}

cl_object
si_mkstemp(cl_object template)
{
	cl_object output;
	cl_index l;
	int fd;

	assert_type_string(template);
	l = template->string.fillp;
	output = cl_alloc_simple_string(l + 6);
	memcpy(output->string.self, template->string.self, l);
	memcpy(output->string.self + l, "XXXXXX", 6);
#ifdef HAVE_MKSTEMP
	fd = mkstemp(output->string.self);
#else
	mktemp(output->string.self);
	fd = open(fd, O_CREAT|O_TRUNC);
#endif
	if (fd < 0)
		@(return Cnil)
	close(fd);
	@(return output)
}
