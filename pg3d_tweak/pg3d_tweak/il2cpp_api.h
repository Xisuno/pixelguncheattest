// il2cpp_api.h – subset da API IL2CPP necessária para o cheat
// Todas as funções são resolvidas em runtime via dlsym / pattern scan.
// Não inventamos offsets: usamos as exportações públicas da GameAssembly.

#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string>

// ---- tipos opacos ----
typedef struct Il2CppClass    Il2CppClass;
typedef struct Il2CppImage    Il2CppImage;
typedef struct Il2CppDomain   Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct MethodInfo     MethodInfo;
typedef struct Il2CppType     Il2CppType;
typedef struct Il2CppField    Il2CppField;
typedef struct Il2CppString   Il2CppString;
typedef struct Il2CppArray    Il2CppArray;

// Cabeçalho real de objeto IL2CPP (igual em todo runtime IL2CPP, não é
// valor específico de build): klass + monitor. Fonte: il2cpp-object-internals.h
// público do runtime. Precisa de definição completa (não só forward decl)
// porque Il2CppString/Il2CppArray o usam por valor abaixo.
struct Il2CppObject {
    Il2CppClass* klass;
    void*        monitor;
};

// String managed
struct Il2CppString {
    Il2CppObject object;
    int32_t      length;
    uint16_t     chars[1]; // UTF-16
};

// Array managed header
struct Il2CppArrayBounds { uintptr_t length; intptr_t lower_bound; };
struct Il2CppArray {
    Il2CppObject            object;
    Il2CppArrayBounds*      bounds;
    uintptr_t               max_length;
    // elements follow
};

// Tipos Unity básicos (tamanhos fixos no IL2CPP)
struct Vector2 { float x, y; };
struct Vector3 { float x, y, z; };
struct Vector4 { float x, y, z, w; };
struct Quaternion { float x, y, z, w; };
struct Color { float r, g, b, a; };
// Nome "Rect" colide com struct Rect de MacTypes.h (QuickDraw legado,
// incluído transitivamente pelo SDK do iOS). Renomeado para evitar a redefinição.
struct Il2CppRect { float x, y, width, height; };
struct Matrix4x4 { float m[16]; }; // column-major

// ---- ponteiros de função (preenchidos em HookManager.mm) ----
extern "C" {

typedef Il2CppDomain*   (*t_il2cpp_domain_get)(void);
typedef Il2CppAssembly* (*t_il2cpp_domain_assembly_open)(Il2CppDomain*, const char*);
typedef Il2CppImage*    (*t_il2cpp_assembly_get_image)(Il2CppAssembly*);
typedef Il2CppClass*    (*t_il2cpp_class_from_name)(Il2CppImage*, const char*, const char*);
typedef MethodInfo*     (*t_il2cpp_class_get_method_from_name)(Il2CppClass*, const char*, int);
typedef Il2CppField*    (*t_il2cpp_class_get_field_from_name)(Il2CppClass*, const char*);
typedef void            (*t_il2cpp_field_get_value)(Il2CppObject*, Il2CppField*, void*);
typedef void            (*t_il2cpp_field_set_value)(Il2CppObject*, Il2CppField*, void*);
typedef bool            (*t_il2cpp_class_is_assignable_from)(Il2CppClass*, Il2CppClass*);
typedef Il2CppClass*    (*t_il2cpp_object_get_class)(Il2CppObject*);
typedef Il2CppObject*   (*t_il2cpp_runtime_invoke)(MethodInfo*, void*, void**, void**);
typedef uint8_t*        (*t_il2cpp_array_addr_with_size)(Il2CppArray*, int32_t, uintptr_t);
typedef uintptr_t       (*t_il2cpp_array_length)(Il2CppArray*);

// Introspecção (opcional): escolher overload por assinatura e listar campos.
// Se algum símbolo faltar, só os recursos que dependem dele ficam indisponíveis.
typedef MethodInfo*       (*t_il2cpp_class_get_methods)(Il2CppClass*, void** iter);
typedef const char*       (*t_il2cpp_method_get_name)(MethodInfo*);
typedef uint32_t          (*t_il2cpp_method_get_param_count)(MethodInfo*);
typedef const Il2CppType* (*t_il2cpp_method_get_param)(MethodInfo*, uint32_t index);
typedef char*             (*t_il2cpp_type_get_name)(const Il2CppType*);
typedef Il2CppField*      (*t_il2cpp_class_get_fields)(Il2CppClass*, void** iter);
typedef const char*       (*t_il2cpp_field_get_name)(Il2CppField*);
typedef size_t            (*t_il2cpp_field_get_offset)(Il2CppField*);
typedef const Il2CppType* (*t_il2cpp_field_get_type)(Il2CppField*);
typedef Il2CppClass*      (*t_il2cpp_class_get_parent)(Il2CppClass*);

// String helpers
typedef Il2CppString*   (*t_il2cpp_string_new)(const char*);
typedef char*           (*t_il2cpp_string_chars)(Il2CppString*);

// Il2CppImage para Assembly-CSharp
typedef Il2CppImage*    (*t_il2cpp_get_corlib)(void);

// FindObjectsOfType equivalente: resolve via icall
typedef void*           (*t_resolve_icall)(const char*);

} // extern "C"

// ---- struct com todos os ponteiros ----
struct Il2CppAPI {
    t_il2cpp_domain_get                    domain_get;
    t_il2cpp_domain_assembly_open          domain_assembly_open;
    t_il2cpp_assembly_get_image            assembly_get_image;
    t_il2cpp_class_from_name               class_from_name;
    t_il2cpp_class_get_method_from_name    class_get_method_from_name;
    t_il2cpp_class_get_field_from_name     class_get_field_from_name;
    t_il2cpp_field_get_value               field_get_value;
    t_il2cpp_field_set_value               field_set_value;
    t_il2cpp_object_get_class              object_get_class;
    t_il2cpp_runtime_invoke                runtime_invoke;
    t_il2cpp_array_addr_with_size          array_addr_with_size;
    t_il2cpp_array_length                  array_length;
    t_il2cpp_string_new                    string_new;
    t_resolve_icall                        resolve_icall;
    t_il2cpp_class_get_methods             class_get_methods;
    t_il2cpp_method_get_name               method_get_name;
    t_il2cpp_method_get_param_count        method_get_param_count;
    t_il2cpp_method_get_param              method_get_param;
    t_il2cpp_type_get_name                 type_get_name;
    t_il2cpp_class_get_fields              class_get_fields;
    t_il2cpp_field_get_name                field_get_name;
    t_il2cpp_field_get_offset              field_get_offset;
    t_il2cpp_field_get_type                field_get_type;
    t_il2cpp_class_get_parent              class_get_parent;
    bool                                   ready;
};

extern Il2CppAPI g_il2cpp;

// ---- helpers inline ----
inline void* FieldAddr(Il2CppObject* obj, ptrdiff_t offset) {
    return reinterpret_cast<uint8_t*>(obj) + offset;
}
template<typename T>
inline T& Field(Il2CppObject* obj, ptrdiff_t offset) {
    return *reinterpret_cast<T*>(reinterpret_cast<uint8_t*>(obj) + offset);
}
// Lê string IL2CPP como std::string utf8 simples (ASCII safe)
inline std::string Il2CppStringToStd(Il2CppString* s) {
    if (!s || s->length <= 0) return "";
    std::string out;
    out.reserve(s->length);
    for (int i = 0; i < s->length; i++) {
        uint16_t c = s->chars[i];
        out += (c < 128) ? (char)c : '?';
    }
    return out;
}
