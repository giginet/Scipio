#ifndef CORE_CORE_H
#define CORE_CORE_H

// Same-module public header include.
#include <core/core_types.h>
// Inline-implementation file: textually included, must ship with the framework.
#include <core/core_inline.inl>
// Quoted include in the search-path style: no such file exists next to this header,
// so only the -I entries SwiftPM injects can resolve it in source builds.
#include "core/core_quoted.h"

core_answer_t core_answer(void);

#endif /* CORE_CORE_H */
