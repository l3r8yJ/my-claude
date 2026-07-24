---
name: mapstruct-converter-conventions
description: Use when writing a Spring Converter, a MapStruct mapper, or calling ConversionService - naming, shared @MapperConfig, and multi-input conversion conventions.
---

# Converter Beans and ConversionService

- Prefer a MapStruct-generated `Converter<S, T>` over a hand-written Spring `Converter` bean or an ad-hoc mapping function. Define one shared `@MapperConfig` (e.g. `MapstructConfig`) with `componentModel = MappingConstants.ComponentModel.SPRING` and `unmappedTargetPolicy = ReportingPolicy.ERROR`, so every mapper shares the same settings and a build fails fast on an unmapped target field instead of silently leaving it null. Route shared named helper methods and nested-type delegation to the registered `ConversionService` through that same shared config's `uses = [...]`, rather than repeating `uses` on each mapper.
- Naming convention: `interface {Source}2{Target}Converter : Converter<Source, Target>` (or `abstract class` when a method body is required), annotated `@Mapper(config = SharedMapperConfig::class)`, with `override fun convert(...)`. Use `@Mapping(target = "...", source = "...")` for field renames instead of manual field-by-field assignment.
- Reserve fully hand-written `convert()` bodies for conversions MapStruct can't express (a single computed value, a non-bean-shaped source) — keep the `@Mapper(config = ...)` annotation on the `abstract class : Converter<S, T>` even then, so it still registers the same way as a generated mapper.
- Registration is automatic either way: Spring Boot's MVC auto-configuration detects every `Converter`/`GenericConverter`/`Formatter` bean (hand-written or MapStruct-generated) and registers it into the `mvcConversionService` `ConversionService` bean — do not hand-write a `GenericConversionService`/`FormatterRegistry` config class. Inject `ConversionService` (qualify with `@Qualifier("mvcConversionService")` only when more than one `ConversionService` bean exists in context) and call `convert`/`convertNotNull`.
- For a mapping that needs more than one input, keep the `Converter<S, T>` shape by wrapping the extra inputs in the `Source<S, A>` pair type (see below) rather than widening `S` into a bespoke multi-field holder class.

## Multi-input conversions

For a `Converter` that needs more than one input, use a generic `Source<S, A>` pair type instead of a one-off `XxxEntitySource` data class per converter:

```kotlin
data class Source<S, A>(val source: S, val addition: A)

infix fun <S, A> S.with(addition: A): Source<S, A> = Source(this, addition)

interface OrderEntity2OrderConverter : Converter<Source<OrderEntity, CustomerContext>, Order>
```

Pair it with a reified `ConversionService.convertNotNull<Source, Target>(source): Target` extension instead of `convert(...)!!` or a hand-rolled `convertOrThrow`:

```kotlin
inline fun <reified S, reified T> ConversionService.convertNotNull(source: S): T =
    convert(source, T::class.java) ?: error("Conversion from ${S::class} to ${T::class} returned null")

val order: Order = conversionService.convertNotNull(orderEntity with customerContext)
```
