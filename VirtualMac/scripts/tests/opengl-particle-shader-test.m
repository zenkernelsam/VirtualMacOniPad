#import "../../vz/guest/OpenGLPVGCompat.m"

static void Require(BOOL condition, const char *name) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *source =
            @"#version 330\n"
            "#define TRANSFORM_ALIGN_DISABLED uint(0)\n"
            "#define TRANSFORM_ALIGN_Z_BILLBOARD uint(1)\n"
            "#define TRANSFORM_ALIGN_Y_TO_VELOCITY uint(2)\n"
            "#define TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY uint(3)\n"
            "uniform highp uint align_mode;\n"
            "flat out highp uvec4 instance_color_custom_data;\n"
            "void main() {\n"
            "vec4 value = vec4(9.0);\n"
            "switch (align_mode) {\n"
            "case TRANSFORM_ALIGN_DISABLED: {\n} break;\n"
            "case TRANSFORM_ALIGN_Z_BILLBOARD: {\nvalue.x = 1.0;\n} break;\n"
            "case TRANSFORM_ALIGN_Y_TO_VELOCITY: {\nvalue.y = 2.0;\n} break;\n"
            "case TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY: {\nvalue.z = 3.0;\n} break;\n"
            "}\n"
            "instance_color_custom_data = uvec4(value);\n"
            "}\n";
        NSString *expected = [source stringByReplacingOccurrencesOfString:
            @"switch (align_mode) {" withString:@"{"];
        NSArray<NSString *> *names = @[
            @"TRANSFORM_ALIGN_DISABLED", @"TRANSFORM_ALIGN_Z_BILLBOARD",
            @"TRANSFORM_ALIGN_Y_TO_VELOCITY",
            @"TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY"
        ];
        for (NSUInteger index = 0; index < names.count; ++index) {
            expected = [expected stringByReplacingOccurrencesOfString:
                [NSString stringWithFormat:@"case %@: {", names[index]]
                withString:[NSString stringWithFormat:@"%@if (align_mode == %@) {",
                    index == 0 ? @"" : @"else ", names[index]]];
        }
        expected = [expected stringByReplacingOccurrencesOfString:
            @"} break;" withString:@"}"];
        Require([CompatibleParticleShaderSource(source) isEqualToString:expected],
                "known four-case source has only the prescribed control-flow changes");
        NSString *mode3d = [@"#define MODE_3D\n" stringByAppendingString:source];
        Require([CompatibleParticleShaderSource(mode3d) isEqualToString:
            [@"#define MODE_3D\n" stringByAppendingString:expected]],
            "3D variant retains its define and the same branch bodies");
        Require(CompatibleParticleShaderSource(nil) == nil, "nil source remains nil");
        NSString *ordinary = @"void main() { gl_Position = vec4(0); }";
        Require(CompatibleParticleShaderSource(ordinary) == ordinary,
                "unrelated shader is returned unchanged");
        NSArray<NSString *> *unknown = @[
            [source stringByReplacingOccurrencesOfString:@"uint(3)" withString:@"uint(2)"],
            [source stringByReplacingOccurrencesOfString:
                @"uniform highp uint align_mode;" withString:@"uint align_mode;"],
            [source stringByReplacingOccurrencesOfString:@"} break;" withString:@"}"],
            [[source stringByReplacingOccurrencesOfString:
                @"case TRANSFORM_ALIGN_DISABLED: {\n} break;"
                withString:@"case TRANSFORM_ALIGN_DISABLED: {\n}"]
                stringByAppendingString:@"\n{ } break;"],
            [source stringByReplacingOccurrencesOfString:@"value.x = 1.0;"
                withString:@"} value.x = 1.0; {"],
            [source stringByReplacingOccurrencesOfString:@"switch (align_mode) {"
                withString:@"switch (align_mode) { default: {} break;"],
            [source stringByAppendingString:@"switch (extra) { case 4: break; }"],
            [source stringByReplacingOccurrencesOfString:
                @"case TRANSFORM_ALIGN_DISABLED: {" withString:
                @"case TRANSFORM_ALIGN_DISABLED:"],
            [source stringByReplacingOccurrencesOfString:
                @"case TRANSFORM_ALIGN_DISABLED: {\n} break;\n"
                "case TRANSFORM_ALIGN_Z_BILLBOARD: {\nvalue.x = 1.0;\n} break;"
                withString:@"case TRANSFORM_ALIGN_Z_BILLBOARD: {\nvalue.x = 1.0;\n} break;\n"
                "case TRANSFORM_ALIGN_DISABLED: {\n} break;"]
        ];
        for (NSString *variant in unknown)
            Require(CompatibleParticleShaderSource(variant) == variant,
                    "unknown control flow or constants are returned unchanged");
        NSMutableString *oversized = [source mutableCopy];
        while (oversized.length <= 2 * 1024 * 1024)
            [oversized appendString:source];
        Require(CompatibleParticleShaderSource(oversized) == oversized,
                "oversized input is returned unchanged");
        printf("PASS: particle shader lowering and unchanged-input guards\n");
    }
    return 0;
}
